#!/usr/bin/env bash
set -euo pipefail

# Installs OpenChoreo on a local kind cluster end to end.
# Assumes configurations are under bootstrap/config/ and bootstrap/samples/.

GATEWAY_API_VERSION="v1.5.1"
CERT_MANAGER_VERSION="v1.19.4"
ESO_VERSION="2.0.1"
KGATEWAY_VERSION="v2.3.1"
OPENBAO_CHART_VERSION="0.25.6"
THUNDER_VERSION="0.28.0"
LOGS_OPENSEARCH_VERSION="0.5.3"
TRACES_OPENSEARCH_VERSION="0.6.0"
METRICS_PROMETHEUS_VERSION="0.7.0"
EVENTS_OTEL_COLLECTOR_VERSION="0.1.1"

CLUSTER_NAME="openchoreo"
HELM_REPO="oci://ghcr.io/openchoreo/helm-charts"
CONTROL_PLANE_NS="openchoreo-control-plane"
DATA_PLANE_NS="openchoreo-data-plane"
WORKFLOW_PLANE_NS="openchoreo-workflow-plane"
OBSERVABILITY_NS="openchoreo-observability-plane"
THUNDER_NS="thunder"
OPENBAO_NS="openbao"

OPENCHOREO_VERSION="v1.1.6"
OPENCHOREO_CHART_VERSION="1.1.6"

KUBECTL="kubectl --context kind-${CLUSTER_NAME}"
HELM="helm --kube-context kind-${CLUSTER_NAME}"

step() { echo ""; echo "==> $1"; }
info() { echo "    $1"; }
fail() { echo "ERROR: $1" >&2; exit 1; }

require_tools() {
    local missing=()
    for t in kind kubectl helm docker python3; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    [[ ${#missing[@]} -eq 0 ]] || fail "missing required tools: ${missing[*]}"
    docker info >/dev/null 2>&1 || fail "docker daemon is not reachable"
}

create_cluster() {
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        info "cluster '${CLUSTER_NAME}' already exists, skipping creation"
    else
        step "Creating kind cluster '${CLUSTER_NAME}'"
        kind create cluster --config kind.yaml
    fi
}

patch_coredns() {
    step "Patching CoreDNS ConfigMap for local hostnames"
    $KUBECTL get configmap coredns -n kube-system -o yaml > bootstrap/config/coredns-original.yaml
    
    # Use python to insert the rewrite rules into the Corefile inside the .:53 block
    python3 -c '
import yaml, sys

with open("bootstrap/config/coredns-original.yaml", "r") as f:
    cm = yaml.safe_load(f)

corefile = cm["data"]["Corefile"]
if "host.k3d.internal" not in corefile:
    lines = corefile.split("\n")
    new_lines = []
    inserted = False
    for line in lines:
        if "ready" in line and not inserted:
            # We insert rewrite rules to map openchoreo domains to the host gateway
            new_lines.append("    rewrite stop name regex (.+\\.)?openchoreo\\.localhost host.k3d.internal")
            new_lines.append("    rewrite stop name regex (.+\\.)?openchoreoapis\\.localhost host.k3d.internal")
            inserted = True
        new_lines.append(line)
    cm["data"]["Corefile"] = "\n".join(new_lines)

with open("bootstrap/config/coredns-patched.yaml", "w") as f:
    yaml.dump(cm, f)
'
    $KUBECTL apply -f bootstrap/config/coredns-patched.yaml
    $KUBECTL rollout restart deployment coredns -n kube-system
    $KUBECTL rollout status deployment coredns -n kube-system --timeout=60s
}

install_prerequisites() {
    step "Installing Gateway API CRDs (${GATEWAY_API_VERSION})"
    $KUBECTL apply --server-side \
        -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

    step "Installing cert-manager (${CERT_MANAGER_VERSION})"
    $HELM upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
        --namespace cert-manager --create-namespace \
        --version "$CERT_MANAGER_VERSION" \
        --set crds.enabled=true --wait --timeout 180s

    step "Installing External Secrets Operator (${ESO_VERSION})"
    $HELM upgrade --install external-secrets oci://ghcr.io/external-secrets/charts/external-secrets \
        --namespace external-secrets --create-namespace \
        --version "$ESO_VERSION" \
        --set installCRDs=true --wait --timeout 180s

    step "Installing kgateway (${KGATEWAY_VERSION})"
    $HELM upgrade --install kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
        --create-namespace --namespace "$CONTROL_PLANE_NS" --version "$KGATEWAY_VERSION"
    $HELM upgrade --install kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
        --namespace "$CONTROL_PLANE_NS" --create-namespace --version "$KGATEWAY_VERSION"

    step "Installing OpenBao (${OPENBAO_CHART_VERSION})"
    $HELM upgrade --install openbao oci://ghcr.io/openbao/charts/openbao \
        --namespace "$OPENBAO_NS" --create-namespace \
        --version "$OPENBAO_CHART_VERSION" \
        --values bootstrap/config/values-openbao.yaml \
        --wait --timeout 300s

    step "Creating ClusterSecretStore"
    $KUBECTL apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets-openbao
  namespace: ${OPENBAO_NS}
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: default
spec:
  provider:
    vault:
      server: "http://openbao.${OPENBAO_NS}.svc:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "openchoreo-secret-writer-role"
          serviceAccountRef:
            name: "external-secrets-openbao"
            namespace: "${OPENBAO_NS}"
EOF
}

install_control_plane() {
    step "Installing ThunderID (identity provider)"
    $HELM upgrade --install thunder oci://ghcr.io/asgardeo/helm-charts/thunder \
        --namespace "$THUNDER_NS" --create-namespace \
        --version "$THUNDER_VERSION" \
        --values bootstrap/config/values-thunder.yaml
    $KUBECTL wait -n "$THUNDER_NS" \
        --for=condition=available --timeout=300s deployment -l app.kubernetes.io/name=thunder

    step "Creating backstage ExternalSecret"
    $KUBECTL apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: backstage-secrets
  namespace: ${CONTROL_PLANE_NS}
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: default
  target:
    name: backstage-secrets
  data:
    - secretKey: backend-secret
      remoteRef: { key: backstage-backend-secret, property: value }
    - secretKey: client-secret
      remoteRef: { key: backstage-client-secret, property: value }
    - secretKey: jenkins-api-key
      remoteRef: { key: backstage-jenkins-api-key, property: value }
    - secretKey: github-actions-token
      remoteRef: { key: backstage-github-actions-token, property: value }
    - secretKey: github-oauth-client-secret
      remoteRef: { key: backstage-github-oauth-client-secret, property: value }
EOF
    $KUBECTL wait -n "$CONTROL_PLANE_NS" \
        --for=condition=Ready externalsecret/backstage-secrets --timeout=120s

    step "Installing the control plane"
    $HELM upgrade --install openchoreo-control-plane "$HELM_REPO/openchoreo-control-plane" \
        --version "$OPENCHOREO_CHART_VERSION" \
        --namespace "$CONTROL_PLANE_NS" --create-namespace \
        --values bootstrap/config/values-cp.yaml
    $KUBECTL wait -n "$CONTROL_PLANE_NS" \
        --for=condition=available --timeout=300s deployment --all

    step "Extracting cluster-gateway CA"
    $KUBECTL wait -n "$CONTROL_PLANE_NS" \
        --for=condition=Ready certificate/cluster-gateway-ca --timeout=120s
    local ca_crt
    ca_crt=$($KUBECTL get secret cluster-gateway-ca -n "$CONTROL_PLANE_NS" \
        -o jsonpath='{.data.ca\.crt}' | base64 -d)
    $KUBECTL create configmap cluster-gateway-ca \
        --from-literal=ca.crt="$ca_crt" \
        -n "$CONTROL_PLANE_NS" --dry-run=client -o yaml | $KUBECTL apply -f -
}

install_default_resources() {
    step "Installing default resources"
    $KUBECTL label namespace default openchoreo.dev/control-plane=true --overwrite
    $KUBECTL apply -f bootstrap/samples/all.yaml
}

copy_gateway_ca() {
    local ns="$1"
    $KUBECTL create namespace "$ns" --dry-run=client -o yaml | $KUBECTL apply -f -
    local ca_crt
    ca_crt=$($KUBECTL get configmap cluster-gateway-ca -n "$CONTROL_PLANE_NS" -o jsonpath='{.data.ca\.crt}')
    $KUBECTL create configmap cluster-gateway-ca \
        --from-literal=ca.crt="$ca_crt" \
        -n "$ns" --dry-run=client -o yaml | $KUBECTL apply -f -
}

agent_ca() {
    local ns="$1" cert="$2"
    $KUBECTL wait -n "$ns" --for=condition=Ready "certificate/$cert" --timeout=120s >&2
    $KUBECTL get secret cluster-agent-tls -n "$ns" -o jsonpath='{.data.ca\.crt}' | base64 -d
}

install_data_plane() {
    step "Installing the data plane"
    copy_gateway_ca "$DATA_PLANE_NS"
    $HELM upgrade --install openchoreo-data-plane "$HELM_REPO/openchoreo-data-plane" \
        --version "$OPENCHOREO_CHART_VERSION" \
        --namespace "$DATA_PLANE_NS" --create-namespace \
        --values bootstrap/config/values-dp.yaml

    step "Registering the data plane"
    local ca; ca=$(agent_ca "$DATA_PLANE_NS" cluster-agent-dataplane-tls)
    $KUBECTL apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterDataPlane
metadata:
  name: default
spec:
  planeID: default
  clusterAgent:
    clientCA:
      value: |
$(echo "$ca" | sed 's/^/        /')
  secretStoreRef:
    name: default
  gateway:
    ingress:
      external:
        http:
          host: openchoreoapis.localhost
          listenerName: http
          port: 19080
        name: gateway-default
        namespace: openchoreo-data-plane
EOF
}

install_workflow_plane() {
    step "Installing the workflow plane"
    copy_gateway_ca "$WORKFLOW_PLANE_NS"

    helm repo add twuni https://twuni.github.io/docker-registry.helm >/dev/null 2>&1 || true
    helm repo update twuni >/dev/null
    $HELM upgrade --install registry twuni/docker-registry \
        --namespace "$WORKFLOW_PLANE_NS" --create-namespace \
        --values bootstrap/config/values-registry.yaml

    $HELM upgrade --install openchoreo-workflow-plane "$HELM_REPO/openchoreo-workflow-plane" \
        --version "$OPENCHOREO_CHART_VERSION" \
        --namespace "$WORKFLOW_PLANE_NS" \
        --values bootstrap/config/values-wp.yaml

    step "Installing workflow templates"
    $KUBECTL apply \
        -f bootstrap/samples/workflow-templates/checkout-source.yaml \
        -f bootstrap/samples/workflow-templates.yaml \
        -f bootstrap/samples/workflow-templates/publish-image-k3d.yaml \
        -f bootstrap/samples/workflow-templates/generate-workload-k3d.yaml

    step "Registering the workflow plane"
    local ca; ca=$(agent_ca "$WORKFLOW_PLANE_NS" cluster-agent-workflowplane-tls)
    $KUBECTL apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterWorkflowPlane
metadata:
  name: default
spec:
  planeID: default
  clusterAgent:
    clientCA:
      value: |
$(echo "$ca" | sed 's/^/        /')
  secretStoreRef:
    name: default
EOF
}

install_observability_plane() {
    step "Installing the observability plane"
    copy_gateway_ca "$OBSERVABILITY_NS"

    step "Creating observability ExternalSecrets"
    $KUBECTL apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: opensearch-admin-credentials
  namespace: ${OBSERVABILITY_NS}
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: default
  target:
    name: opensearch-admin-credentials
  data:
    - secretKey: username
      remoteRef: { key: opensearch-username, property: value }
    - secretKey: password
      remoteRef: { key: opensearch-password, property: value }
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: observer-secret
  namespace: ${OBSERVABILITY_NS}
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: default
  target:
    name: observer-secret
  data:
    - secretKey: UID_RESOLVER_OAUTH_CLIENT_SECRET
      remoteRef: { key: observer-oauth-client-secret, property: value }
EOF
    $KUBECTL wait -n "$OBSERVABILITY_NS" \
        --for=condition=Ready externalsecret/opensearch-admin-credentials \
        externalsecret/observer-secret --timeout=120s

    # Fluent Bit needs /etc/machine-id; kind nodes don't have one by default.
    docker exec "${CLUSTER_NAME}-control-plane" sh -c \
        "[ -s /etc/machine-id ] || cat /proc/sys/kernel/random/uuid | tr -d '-' > /etc/machine-id"

    $HELM upgrade --install openchoreo-observability-plane "$HELM_REPO/openchoreo-observability-plane" \
        --version "$OPENCHOREO_CHART_VERSION" \
        --namespace "$OBSERVABILITY_NS" \
        --values bootstrap/config/values-op.yaml \
        --timeout 25m

    step "Installing observability modules"
    $HELM upgrade --install observability-logs-opensearch \
        oci://ghcr.io/openchoreo/helm-charts/observability-logs-opensearch \
        --namespace "$OBSERVABILITY_NS" --version "$LOGS_OPENSEARCH_VERSION" \
        --set openSearchSetup.openSearchSecretName="opensearch-admin-credentials" \
        --set adapter.openSearchSecretName="opensearch-admin-credentials"
    $HELM upgrade --install observability-traces-opensearch \
        oci://ghcr.io/openchoreo/helm-charts/observability-tracing-opensearch \
        --namespace "$OBSERVABILITY_NS" --version "$TRACES_OPENSEARCH_VERSION" \
        --set openSearch.enabled=false \
        --set openSearchSetup.openSearchSecretName="opensearch-admin-credentials"
    $HELM upgrade --install observability-metrics-prometheus \
        oci://ghcr.io/openchoreo/helm-charts/observability-metrics-prometheus \
        --namespace "$OBSERVABILITY_NS" --version "$METRICS_PROMETHEUS_VERSION"

    local sts i
    for sts in prometheus-openchoreo-observability alertmanager-openchoreo-observability; do
        for i in $(seq 1 30); do
            $KUBECTL get statefulset "$sts" -n "$OBSERVABILITY_NS" >/dev/null 2>&1 && break
            [ "$i" -eq 30 ] && fail "prometheus-operator did not create StatefulSet $sts within 60s"
            sleep 2
        done
        $KUBECTL rollout status "statefulset/$sts" -n "$OBSERVABILITY_NS" --timeout=5m
    done

    $HELM upgrade observability-logs-opensearch \
        oci://ghcr.io/openchoreo/helm-charts/observability-logs-opensearch \
        --namespace "$OBSERVABILITY_NS" --version "$LOGS_OPENSEARCH_VERSION" \
        --reuse-values --set fluent-bit.enabled=true

    $HELM upgrade --install observability-events-otel-collector \
        oci://ghcr.io/openchoreo/helm-charts/observability-events-otel-collector \
        --namespace "$OBSERVABILITY_NS" --version "$EVENTS_OTEL_COLLECTOR_VERSION" \
        -f - <<'EOF'
collector:
  extraEnv:
    - name: OPENSEARCH_USERNAME
      valueFrom:
        secretKeyRef:
          name: opensearch-admin-credentials
          key: username
    - name: OPENSEARCH_PASSWORD
      valueFrom:
        secretKeyRef:
          name: opensearch-admin-credentials
          key: password
extraExtensions:
  basicauth/opensearch:
    client_auth:
      username: ${env:OPENSEARCH_USERNAME}
      password: ${env:OPENSEARCH_PASSWORD}
exporters:
  opensearch:
    logs_index: "k8s-events"
    logs_index_time_format: "yyyy-MM-dd"
    http:
      endpoint: "https://opensearch:9200"
      tls:
        insecure_skip_verify: true
      auth:
        authenticator: basicauth/opensearch
pipelineExporters:
  - opensearch
EOF

    step "Registering the observability plane"
    local ca; ca=$(agent_ca "$OBSERVABILITY_NS" cluster-agent-observabilityplane-tls)
    $KUBECTL apply -f - <<EOF
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterObservabilityPlane
metadata:
  name: default
spec:
  planeID: default
  clusterAgent:
    clientCA:
      value: |
$(echo "$ca" | sed 's/^/        /')
  observerURL: http://observer.openchoreo.localhost:11080
EOF

    if $KUBECTL get clusterdataplane default >/dev/null 2>&1; then
        $KUBECTL patch clusterdataplane default --type merge \
            -p '{"spec":{"observabilityPlaneRef":{"kind":"ClusterObservabilityPlane","name":"default"}}}'
    fi
    if $KUBECTL get clusterworkflowplane default >/dev/null 2>&1; then
        $KUBECTL patch clusterworkflowplane default --type merge \
            -p '{"spec":{"observabilityPlaneRef":{"kind":"ClusterObservabilityPlane","name":"default"}}}'
    fi
}

print_summary() {
    step "OpenChoreo installation complete!"
    info "To access OpenChoreo from your host machine, please start the port-forwarding helper script:"
    info "  ./bootstrap/port-forward.sh"
    info ""
    info "Console:  http://openchoreo.localhost:8080  (log in with admin@openchoreo.dev / Admin@123)"
    info "API:      http://api.openchoreo.localhost:8080"
    info "Planes:   control, data, workflow, observability"
    info "Delete:   kind delete cluster --name ${CLUSTER_NAME}"
}

main() {
    require_tools
    create_cluster
    patch_coredns
    install_prerequisites
    install_control_plane
    install_default_resources
    install_data_plane
    install_workflow_plane
    install_observability_plane
    print_summary
}

main
