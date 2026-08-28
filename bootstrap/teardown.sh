#!/usr/bin/env bash
set -euo pipefail

# Deletes both k3d clusters of the OpenChoreo demo. Pass --yes/-y to skip the
# confirmation prompt.
#
# PARTIAL TEARDOWN NOTE:
# If you ever want to remove only the Argo CD Applications while keeping the
# clusters alive, the `default-namespace` Application must be deleted with
# `--cascade=false`:
#
#   kubectl --context k3d-openchoreo-cp -n argocd delete application default-namespace --cascade=false
#
# That Application adopts the pre-existing `default` Namespace, so a cascading
# delete tries to delete `default` itself. Kubernetes forbids removing the
# default namespace, so the request never completes and the Application hangs
# forever on a stuck finalizer.

CLUSTERS=(openchoreo-cp openchoreo-dp-prod)

step() { echo ""; echo "==> $1"; }
info() { echo "    $1"; }
fail() { echo "ERROR: $1" >&2; exit 1; }

ASSUME_YES=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=true ;;
        -h|--help)
            echo "Usage: $0 [--yes|-y]"
            exit 0
            ;;
        *) fail "unknown argument: $arg (usage: $0 [--yes|-y])" ;;
    esac
done

confirm() {
    if [[ "$ASSUME_YES" == true ]]; then
        return 0
    fi
    local answer
    read -r -p "    Delete these clusters and everything in them? [y/N] " answer
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) info "aborted"; exit 0 ;;
    esac
}

main() {
    command -v k3d >/dev/null 2>&1 || fail "k3d is not installed"

    step "The following k3d clusters will be DELETED"
    local c
    for c in "${CLUSTERS[@]}"; do
        info "- $c"
    done

    confirm

    step "Deleting clusters"
    k3d cluster delete "${CLUSTERS[@]}"

    step "Teardown complete"
}

main
