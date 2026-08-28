#!/usr/bin/env bash
set -euo pipefail

# Pushes the OpenChoreo control plane's cluster-gateway CA out to every other
# plane namespace: both data planes, the workflow plane and the observability
# plane.
#
# ONE-WAY, NOT AN EXCHANGE:
# This used to be a two-way exchange. Each plane's cluster-agent minted its own
# self-signed CA, so the control plane had to be told about it afterwards under
# a per-plane `<plane>-agent-ca` secret. That CA did not exist until the plane
# chart had run, so it could never be committed to git.
#
# The plane charts now set `clusterAgent.tls.generateCerts: false`, which makes
# cert-manager issue each agent's client certificate from the control plane's
# own cluster-gateway CA. The control plane trusts that CA by definition, so the
# return leg disappeared: every plane CR under
# platform-shared/cluster-{dataplanes,workflowplanes,observabilityplanes}/*.yaml
# now references `cluster-gateway-ca` directly and nothing has to be collected
# back. All that is left is pushing the CA outwards.
#
# The trade-off is deliberate and demo-scoped: a cert-manager CA Issuer signs
# locally, so it needs the CA's PRIVATE KEY. That is why this script copies the
# whole `cluster-gateway-ca` secret (tls.crt, tls.key, ca.crt) rather than just
# the public certificate. Any plane holding that key can mint a certificate the
# control plane trusts. See the "Trust model" section of README.md.
#
# WHY THIS IS STILL IMPERATIVE AND NOT GITOPS:
# The cluster-gateway CA is minted by the control-plane Helm chart at install
# time. It only exists once that chart has actually run, so it cannot be
# committed to git or rendered by Argo CD.
#
# Each plane namespace needs the CA under TWO different objects, and both are
# load-bearing:
#   * secret    cluster-gateway-ca -> clusterAgent.tls.caSecretName, consumed by
#                                     the agent's cert-manager CA Issuer, which
#                                     needs tls.crt + tls.key to sign.
#   * configmap cluster-gateway-ca -> clusterAgent.tls.serverCAConfigMap, mounted
#                                     at /ca-certs by the agent Deployment so it
#                                     can verify the gateway's server cert.
# Dropping the configmap reintroduces an agent CrashLoop; dropping the secret
# leaves the Certificate permanently unissued.
#
# This script is safe to re-run: every write goes through `apply`, never a
# bare `create`.

CP_CONTEXT="k3d-openchoreo-cp"
DP_PROD_CONTEXT="k3d-openchoreo-dp-prod"
CONTROL_PLANE_NS="openchoreo-control-plane"

# Every namespace that runs a cluster agent and therefore needs both the
# cluster-gateway-ca secret and the cluster-gateway-ca configmap.
# Format context:namespace.
GATEWAY_CA_TARGETS=(
    "${CP_CONTEXT}:openchoreo-data-plane"
    "${CP_CONTEXT}:openchoreo-workflow-plane"
    "${CP_CONTEXT}:openchoreo-observability-plane"
    "${DP_PROD_CONTEXT}:openchoreo-data-plane"
)

step() { echo ""; echo "==> $1"; }
info() { echo "    $1"; }
fail() { echo "ERROR: $1" >&2; exit 1; }

# wait_for_secret <context> <namespace> <secret>
# Polls every 10s for up to ~20 minutes. The secrets are created by charts that
# Argo CD installs asynchronously, so a cold bootstrap legitimately waits a
# long time here.
wait_for_secret() {
    local ctx="$1" ns="$2" secret="$3"
    local attempts=120 i=1

    info "waiting for secret ${secret} in ${ns} on ${ctx} (up to 20m)"
    while [ "$i" -le "$attempts" ]; do
        if kubectl --context "$ctx" -n "$ns" get secret "$secret" >/dev/null 2>&1; then
            [ "$i" -gt 1 ] && echo ""
            info "found ${secret} after $(( (i - 1) * 10 ))s"
            return 0
        fi
        # Progress output matters here: on a cold bootstrap the chart behind this
        # secret is still pulling images, and a silent 20-minute wait is
        # indistinguishable from a wedged script.
        if [ $(( i % 6 )) -eq 0 ]; then
            printf ' [%dm]' "$(( i / 6 ))"
        else
            printf '.'
        fi
        sleep 10
        i=$((i + 1))
    done
    echo ""

    fail "timed out after 20m waiting for secret ${secret} in namespace ${ns} on ${ctx}.
       The secret is minted by the OpenChoreo Helm chart that Argo CD installs.
       Inspect the relevant Argo CD Application:
         cp / ${CONTROL_PLANE_NS}                  -> cp-control-plane
         cp / openchoreo-data-plane                -> cp-data-plane-nonprod
         cp / openchoreo-workflow-plane            -> cp-workflow-plane
         cp / openchoreo-observability-plane       -> cp-observability-plane
         dp-prod / openchoreo-data-plane           -> dp-prod-data-plane
       e.g. kubectl --context ${CP_CONTEXT} -n argocd get application <name> -o yaml"
}

# The control plane's cluster-gateway CA - certificate AND signing key - into
# every plane namespace, as both a secret (for the agent's CA Issuer) and a
# configmap (for the agent Deployment's /ca-certs mount).
push_gateway_ca() {
    step "Distributing the cluster-gateway CA to every plane namespace"
    wait_for_secret "$CP_CONTEXT" "$CONTROL_PLANE_NS" cluster-gateway-ca

    local tls_crt tls_key ca_crt
    tls_crt=$(kubectl --context "$CP_CONTEXT" -n "$CONTROL_PLANE_NS" \
                get secret cluster-gateway-ca -o jsonpath='{.data.tls\.crt}' | base64 -d)
    tls_key=$(kubectl --context "$CP_CONTEXT" -n "$CONTROL_PLANE_NS" \
                get secret cluster-gateway-ca -o jsonpath='{.data.tls\.key}' | base64 -d)
    ca_crt=$(kubectl --context "$CP_CONTEXT" -n "$CONTROL_PLANE_NS" \
               get secret cluster-gateway-ca -o jsonpath='{.data.ca\.crt}' | base64 -d)
    [ -n "$tls_crt" ] || fail "cluster-gateway-ca contains no tls.crt"
    # The private key is what the CA Issuer signs with; without it every agent
    # Certificate stays pending forever.
    [ -n "$tls_key" ] || fail "cluster-gateway-ca contains no tls.key"
    [ -n "$ca_crt" ] || fail "cluster-gateway-ca contains no ca.crt"

    local entry ctx ns
    for entry in "${GATEWAY_CA_TARGETS[@]}"; do
        ctx=${entry%%:*}
        ns=${entry##*:}
        info "installing cluster-gateway-ca secret + configmap in ${ns} on ${ctx}"
        kubectl --context "$ctx" create namespace "$ns" \
            --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -
        # kubernetes.io/tls to match the source secret; a secret's type is
        # immutable, so an Opaque copy here would be a one-way mistake.
        kubectl --context "$ctx" -n "$ns" create secret generic cluster-gateway-ca \
            --type=kubernetes.io/tls \
            --from-literal=tls.crt="$tls_crt" \
            --from-literal=tls.key="$tls_key" \
            --from-literal=ca.crt="$ca_crt" \
            --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -
        kubectl --context "$ctx" -n "$ns" create configmap cluster-gateway-ca \
            --from-literal=ca.crt="$ca_crt" --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -
    done
}

main() {
    push_gateway_ca
    step "Plane linking complete"
}

main
