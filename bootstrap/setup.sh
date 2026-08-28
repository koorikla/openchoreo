#!/usr/bin/env bash
set -euo pipefail

# Bootstraps the OpenChoreo two-cluster demo on k3d.
#
#   openchoreo-cp       kubeAPI 6550 - control/workflow/observability planes,
#                       Argo CD, and a local data plane (dp-nonprod).
#   openchoreo-dp-prod  kubeAPI 6551 - the production data plane (dp-prod).
#
# This script does the bare minimum that cannot be expressed declaratively:
# create the clusters, patch DNS, install the Gateway API CRDs and Argo CD,
# register dp-prod with Argo CD, and hand over to the root app-of-apps.
# Everything else lives in git under argocd/ and is owned by Argo CD.

CP_CLUSTER="openchoreo-cp"
DP_PROD_CLUSTER="openchoreo-dp-prod"
CP_CONTEXT="k3d-${CP_CLUSTER}"
DP_PROD_CONTEXT="k3d-${DP_PROD_CLUSTER}"

CP_CONFIG="bootstrap/clusters/cp.yaml"
DP_PROD_CONFIG="bootstrap/clusters/dp-prod.yaml"
COREDNS_CUSTOM="bootstrap/coredns-custom.yaml"

GATEWAY_API_VERSION="v1.6.1"
ARGOCD_CHART_VERSION="10.4.0"

step() { echo ""; echo "==> $1"; }
info() { echo "    $1"; }
fail() { echo "ERROR: $1" >&2; exit 1; }

require_tools() {
    step "Checking required tools"
    local missing=()
    for t in k3d kubectl helm docker; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        for t in "${missing[@]}"; do
            if [[ "$t" == "k3d" ]]; then
                info "k3d is not installed - install it with: brew install k3d"
            fi
        done
        fail "missing required tools: ${missing[*]}"
    fi
    docker info >/dev/null 2>&1 || fail "docker daemon is not reachable"
    info "k3d, kubectl, helm, docker present; docker daemon reachable"
}

create_clusters() {
    step "Creating k3d clusters"
    local existing
    existing=$(k3d cluster list --no-headers 2>/dev/null | awk '{print $1}')

    local entry name config
    for entry in "${CP_CLUSTER}:${CP_CONFIG}" "${DP_PROD_CLUSTER}:${DP_PROD_CONFIG}"; do
        name=${entry%%:*}
        config=${entry##*:}
        if echo "$existing" | grep -qx "$name"; then
            info "cluster '${name}' already exists, skipping creation"
        else
            info "creating cluster '${name}' from ${config}"
            k3d cluster create --config "$config"
        fi
    done
}

patch_coredns() {
    # Rewrites *.openchoreo.localhost and *.openchoreoapis.localhost to
    # host.k3d.internal so pods resolve host-published ports, including
    # across the two clusters.
    step "Patching CoreDNS on both clusters"
    local ctx
    for ctx in "$CP_CONTEXT" "$DP_PROD_CONTEXT"; do
        info "applying ${COREDNS_CUSTOM} to ${ctx}"
        kubectl --context "$ctx" apply -f "$COREDNS_CUSTOM"
        kubectl --context "$ctx" rollout restart deployment coredns -n kube-system
        kubectl --context "$ctx" rollout status deployment coredns -n kube-system --timeout=5m
    done
}

install_gateway_api_crds() {
    # Imperative on purpose: this is a raw GitHub release URL, and an Argo CD
    # Application has no non-git source type that can pull a plain manifest
    # from an arbitrary HTTP address. Server-side apply keeps it re-runnable.
    step "Installing Gateway API CRDs (${GATEWAY_API_VERSION}) on both clusters"
    local url="https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
    local ctx
    for ctx in "$CP_CONTEXT" "$DP_PROD_CONTEXT"; do
        info "applying Gateway API CRDs to ${ctx}"
        kubectl --context "$ctx" apply --server-side -f "$url"
    done
}

install_argocd() {
    step "Installing Argo CD ${ARGOCD_CHART_VERSION} on ${CP_CLUSTER}"
    helm repo add argo https://argoproj.github.io/argo-helm
    helm repo update argo

    # --insecure: Argo CD's server terminates behind the gateway, which speaks
    #   plain HTTP to it, so the server must not redirect to HTTPS itself.
    # applicationsetcontroller.enable.progressive.syncs: turns on ApplicationSet
    #   RollingSync, which the platform ApplicationSets rely on. The flag lands
    #   in the argocd-cmd-params-cm ConfigMap.
    helm --kube-context "$CP_CONTEXT" upgrade --install argocd argo/argo-cd \
        --namespace argocd --create-namespace --version "$ARGOCD_CHART_VERSION" \
        --set 'server.extraArgs={--insecure}' \
        --set configs.params."applicationsetcontroller\.enable\.progressive\.syncs"=true \
        --wait --timeout 10m
}

register_dp_prod() {
    # Build the Argo CD cluster Secret by hand rather than using
    # `argocd cluster add`: that CLI records the kubeconfig's 0.0.0.0 server
    # address, which is unreachable from inside the cp cluster, and it would
    # add a dependency on the argocd binary. bootstrap/clusters/dp-prod.yaml
    # sets --tls-san=host.k3d.internal so this address validates.
    #
    # The name MUST be exactly "dp-prod": the platform ApplicationSets target
    # `destination.name: dp-prod`, and a mismatch surfaces only as an
    # unhelpful "cluster not found" on the child Applications.
    step "Registering ${DP_PROD_CLUSTER} with Argo CD"
    local ctx="$DP_PROD_CONTEXT" name="dp-prod" port=6551
    local ca cert key
    ca=$(kubectl --context "$ctx" config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
    cert=$(kubectl --context "$ctx" config view --raw --minify -o jsonpath='{.users[0].user.client-certificate-data}')
    key=$(kubectl --context "$ctx" config view --raw --minify -o jsonpath='{.users[0].user.client-key-data}')
    [ -n "$ca" ] && [ -n "$cert" ] && [ -n "$key" ] || fail "could not extract dp-prod credentials"

    kubectl --context "$CP_CONTEXT" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-$name
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
stringData:
  name: $name
  server: https://host.k3d.internal:$port
  config: |
    {"tlsClientConfig":{"insecure":false,"caData":"$ca","certData":"$cert","keyData":"$key"}}
EOF
    info "registered cluster '${name}' at https://host.k3d.internal:${port}"
}

apply_root_app() {
    # ORDER IS LOAD-BEARING. argocd/project.yaml sits outside the root
    # Application's `path: argocd/apps`, so the root app never manages the
    # AppProject - yet the root app and every child declare
    # `project: openchoreo`. If the AppProject is not applied first, the root
    # Application is rejected with "Application referencing project openchoreo
    # which does not exist".
    step "Applying the AppProject and root app-of-apps"
    kubectl --context "$CP_CONTEXT" apply \
        -f argocd/project.yaml \
        -f argocd/root-application.yaml
    info "Argo CD now owns the addons, planes and platform Applications"
}

link_planes() {
    step "Linking the control plane and data planes"
    bootstrap/link-planes.sh
}

print_summary() {
    step "Bootstrap complete"
    info "Console:         http://openchoreo.localhost:8080"
    info "API:             http://api.openchoreo.localhost:8080"
    info "Argo CD:         http://argocd.openchoreo.localhost:8080"
    info "Argo Workflows:  http://localhost:10081"
    info "Observer:        http://observer.openchoreo.localhost:11080"
    info ""
    info "Argo CD admin password:"
    info "  kubectl --context ${CP_CONTEXT} -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    info ""
    info "Teardown:"
    info "  ./bootstrap/teardown.sh"
}

main() {
    require_tools
    create_clusters
    patch_coredns
    install_gateway_api_crds
    install_argocd
    register_dp_prod
    apply_root_app
    link_planes
    print_summary
}

main
