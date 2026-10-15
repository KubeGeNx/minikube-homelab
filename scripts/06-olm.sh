#!/usr/bin/env bash
# Installs/uninstalls Operator Lifecycle Manager (OLM). Not Helm-packaged,
# so it lives outside the ApplicationSet -- selected by the resolved catalogue
# plan and called by scripts/04-apply-apps.sh.
# Usage: 06-olm.sh install|uninstall
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV="${ENV:-dev}"
PLAN_FILE="$ROOT_DIR/gitops/rendered/$ENV/platform-plan.json"
if [ ! -f "$PLAN_FILE" ]; then
  echo "ERROR: platform plan missing for ENV=$ENV. Run scripts/build-applicationset.sh first." >&2
  exit 1
fi
OLM_VERSION="$(jq -r '.versions.OLM_VERSION // empty' "$PLAN_FILE")"
[ -n "$OLM_VERSION" ] || { echo "ERROR: OLM_VERSION missing from resolved plan." >&2; exit 1; }

BASE="https://github.com/operator-framework/operator-lifecycle-manager/releases/download/${OLM_VERSION}"
ACTION="${1:-install}"

case "$ACTION" in
  install)
    if kubectl -n olm get deployment olm-operator >/dev/null 2>&1; then
      echo "OLM already installed (olm-operator deployment exists), ensuring version ${OLM_VERSION}..."
    else
      echo "Installing OLM ${OLM_VERSION}..."
    fi
    # Server-side apply: OLM's CRDs exceed the client-side annotation size
    # limit. --force-conflicts: on re-runs (or after OLM's own controllers
    # touched fields) another field manager owns parts of these objects and
    # a plain SSA fails with a conflict -- forcing is correct here because
    # the release manifests are the desired state.
    kubectl apply --server-side --force-conflicts -f "${BASE}/crds.yaml"
    kubectl wait --for=condition=Established crd/clusterserviceversions.operators.coreos.com --timeout=120s
    kubectl apply --server-side --force-conflicts -f "${BASE}/olm.yaml"
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
