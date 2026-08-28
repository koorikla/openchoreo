#!/usr/bin/env bash
set -euo pipefail

# Exchanges the mTLS CAs between the OpenChoreo control plane and every other
# plane: both data planes, the workflow plane and the observability plane.
#
# WHY THIS IS IMPERATIVE AND NOT GITOPS:
# Both CAs are minted by the Helm charts at install time - the control plane's
# cluster-gateway CA and each plane agent's own CA only exist once those charts
# have actually run in a cluster. They therefore cannot be committed to git and
# cannot be rendered by Argo CD; the only thing that can be declared statically
# is the *reference* to them, which is what
# platform-shared/cluster-{dataplanes,workflowplanes,observabilityplanes}/*.yaml
# do via clientCA.secretKeyRef.
#
# This script is safe to re-run: every write goes through `apply`, never a
# bare `create`.

CP_CONTEXT="k3d-openchoreo-cp"
DP_PROD_CONTEXT="k3d-openchoreo-dp-prod"
CONTROL_PLANE_NS="openchoreo-control-plane"
DATA_PLANE_NS="openchoreo-data-plane"

# context:plane-name pairs. dp-nonprod lives inside the cp cluster.
PLANES=(
    "${CP_CONTEXT}:dp-nonprod"
    "${DP_PROD_CONTEXT}:dp-prod"
)

# Exchange 2 sources: where each agent mints its cluster-agent-tls secret, and
# the control-plane secret name the matching CR references through
# spec.clusterAgent.clientCA.secretKeyRef. Format context:namespace:secret-name.
AGENT_CA_SOURCES=(
    "${CP_CONTEXT}:openchoreo-data-plane:dp-nonprod-agent-ca"
    "${DP_PROD_CONTEXT}:openchoreo-data-plane:dp-prod-agent-ca"
    "${CP_CONTEXT}:openchoreo-workflow-plane:workflow-plane-agent-ca"
    "${CP_CONTEXT}:openchoreo-observability-plane:observability-plane-agent-ca"
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

# Exchange 1: the control plane's cluster-gateway CA into both data-plane
# namespaces, so each agent trusts the gateway it dials.
push_gateway_ca() {
    step "Distributing the cluster-gateway CA to both data planes"
    wait_for_secret "$CP_CONTEXT" "$CONTROL_PLANE_NS" cluster-gateway-ca

    local ca
    ca=$(kubectl --context "$CP_CONTEXT" -n "$CONTROL_PLANE_NS" \
           get secret cluster-gateway-ca -o jsonpath='{.data.ca\.crt}' | base64 -d)
    [ -n "$ca" ] || fail "cluster-gateway-ca contains no ca.crt"

    local entry ctx plane
    for entry in "${PLANES[@]}"; do
        ctx=${entry%%:*}
        plane=${entry##*:}
        info "installing cluster-gateway-ca configmap for ${plane} on ${ctx}"
        kubectl --context "$ctx" create namespace "$DATA_PLANE_NS" \
            --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -
        kubectl --context "$ctx" -n "$DATA_PLANE_NS" create configmap cluster-gateway-ca \
            --from-literal=ca.crt="$ca" --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -
    done
}

# Exchange 2: each plane agent's own CA back into the control plane, under the
# secret name the matching CR references through
# spec.clusterAgent.clientCA.secretKeyRef (key ca.crt, namespace
# openchoreo-control-plane).
pull_agent_cas() {
    step "Collecting the plane agent CAs into the control plane"
    local entry ctx rest ns secret agent_ca
    for entry in "${AGENT_CA_SOURCES[@]}"; do
        ctx=${entry%%:*}
        rest=${entry#*:}
        ns=${rest%%:*}
        secret=${rest##*:}

        wait_for_secret "$ctx" "$ns" cluster-agent-tls
        agent_ca=$(kubectl --context "$ctx" -n "$ns" \
                     get secret cluster-agent-tls -o jsonpath='{.data.ca\.crt}' | base64 -d)
        [ -n "$agent_ca" ] || fail "cluster-agent-tls in ${ns} on ${ctx} contains no ca.crt"

        info "installing ${secret} in ${CONTROL_PLANE_NS}"
        kubectl --context "$CP_CONTEXT" -n "$CONTROL_PLANE_NS" \
            create secret generic "$secret" --from-literal=ca.crt="$agent_ca" \
            --dry-run=client -o yaml | kubectl --context "$CP_CONTEXT" apply -f -
    done
}

main() {
    push_gateway_ca
    pull_agent_cas
    step "Plane linking complete"
}

main
