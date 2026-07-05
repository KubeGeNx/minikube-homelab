#!/usr/bin/env bash
# Installs/uninstalls Operator Lifecycle Manager (OLM). Not Helm-packaged,
# so like Kubeflow it lives outside the ApplicationSet -- called by
# scripts/04-apply-apps.sh based on OLM_ENABLED in components.env.
# Usage: 06-olm.sh install|uninstall
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"

BASE="https://github.com/operator-framework/operator-lifecycle-manager/releases/download/${OLM_VERSION}"
ACTION="${1:-install}"

case "$ACTION" in
  install)
    if kubectl -n olm get deployment olm-operator >/dev/null 2>&1; then
      echo "OLM already installed (olm-operator deployment exists), ensuring version ${OLM_VERSION}..."
    else
      echo "Installing OLM ${OLM_VERSION}..."
    fi
    # Server-side apply: OLM's CRDs exceed the client-side annotation size limit.
    kubectl apply --server-side -f "${BASE}/crds.yaml"
    kubectl wait --for=condition=Established crd/clusterserviceversions.operators.coreos.com --timeout=120s
    kubectl apply --server-side -f "${BASE}/olm.yaml"
    echo "Waiting for OLM deployments..."
    kubectl -n olm rollout status deployment/olm-operator --timeout=300s
    kubectl -n olm rollout status deployment/catalog-operator --timeout=300s
    echo "Waiting for packageserver CSV to succeed..."
    elapsed=0
    while [ "$elapsed" -lt 300 ]; do
      phase="$(kubectl -n olm get csv packageserver -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
      [ "$phase" = "Succeeded" ] && { echo "packageserver: Succeeded"; break; }
      sleep 5; elapsed=$((elapsed + 5))
    done
    [ "${phase:-}" = "Succeeded" ] || echo "WARNING: packageserver not Succeeded yet (last: ${phase:-unknown}); check 'kubectl -n olm get csv'"
    ;;
  uninstall)
    if ! kubectl get namespace olm >/dev/null 2>&1; then
      echo "OLM not installed -- nothing to do"
      exit 0
    fi
    echo "Uninstalling OLM..."
    kubectl delete -f "${BASE}/olm.yaml" --ignore-not-found --wait=false
    kubectl delete -f "${BASE}/crds.yaml" --ignore-not-found --wait=false
    ;;
  *)
    echo "Usage: $0 install|uninstall"; exit 1 ;;
esac
