#!/usr/bin/env bash
# Full teardown: removes every component this platform installed, then
# deletes the Minikube VM itself. Safe to re-run -- every step is
# best-effort and tolerates things already being gone.
#
# Order matters: Applications are deleted (cascading to their resources via
# the resources-finalizer) *while Argo CD's controllers are still running*,
# so the cascade actually happens; only after that do we remove Argo CD
# itself and, by default, the whole Minikube VM.
#
# Usage:
#   ./cleanup.sh                  # confirm, then tear down everything + delete the Minikube VM
#   ./cleanup.sh --keep-minikube  # tear down components/Argo CD/CRDs but leave the VM running
#   ./cleanup.sh --yes            # skip the confirmation prompt (for non-interactive use)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${MINIKUBE_PROFILE:-homelab}"

KEEP_MINIKUBE=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --keep-minikube) KEEP_MINIKUBE=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help)
      echo "Usage: $0 [--keep-minikube] [--yes]"
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg (see --help)"
      exit 1
      ;;
  esac
done

if [ "$ASSUME_YES" -ne 1 ]; then
  echo "This will delete every component this platform installed (cascading through"
  echo "Argo CD so underlying resources -- namespaces, workloads, volumes -- go too),"
  if [ "$KEEP_MINIKUBE" -eq 1 ]; then
    echo "and leave the Minikube profile '$PROFILE' running (--keep-minikube)."
  else
    echo "then delete the Minikube profile '$PROFILE' entirely."
  fi
  read -r -p "Continue? [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Aborted."; exit 1 ;;
  esac
fi

delete_with_fallback() {
  # Deletes an Argo CD Application, retrying once, then forcing removal by
  # clearing its finalizer as a last resort, so a stuck cascade can never
  # hang this script forever.
  local name="$1"
  echo "  deleting application/$name"
  if kubectl -n argocd delete application "$name" --wait=true --timeout=180s 2>/dev/null; then
    return
  fi
  if ! kubectl -n argocd get application "$name" >/dev/null 2>&1; then
    return
  fi
  echo "    still there after 180s -- retrying (300s)..."
  if kubectl -n argocd delete application "$name" --wait=true --timeout=300s 2>/dev/null; then
    return
  fi
  if ! kubectl -n argocd get application "$name" >/dev/null 2>&1; then
    return
  fi
  echo "    WARNING: forcing removal of '$name' -- its resources may be left behind."
  kubectl -n argocd patch application "$name" --type=merge -p '{"metadata":{"finalizers":null}}' || true
  kubectl -n argocd delete application "$name" --ignore-not-found=true --wait=false || true
}

force_delete_namespace() {
  # Deletes a namespace and actually waits for it to be gone -- unlike
  # `--wait=false`, which returns immediately and can make it look like
  # nothing happened. If it's still stuck Terminating after the timeout
  # (a resource inside it has a finalizer nothing is ever going to clear,
  # e.g. because the controller that owned it -- Argo CD -- already got
  # torn down, or was never tracking it to begin with, as happens if
  # something was deleted manually before this script ran), force it
  # through by stripping the namespace's own finalizers via the
  # Kubernetes API's dedicated /finalize endpoint. This is the standard,
  # well-known way to unstick a namespace and does not depend on Argo CD
  # being involved at all.
  local ns="$1" timeout="${2:-90}"

  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "  namespace/$ns already gone"
    return
  fi

  echo "  deleting namespace/$ns"
  # || true: a timed-out delete exits nonzero, which would kill this whole
  # script under set -e -- but a stuck namespace is exactly the case the
  # force-path below exists to handle.
  kubectl delete namespace "$ns" --wait=true --timeout="${timeout}s" >/dev/null 2>&1 || true
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "    done"
    return
  fi

  echo "    still Terminating after ${timeout}s -- forcing it through by clearing its finalizers"
  kubectl get namespace "$ns" -o json 2>/dev/null \
    | jq '.spec.finalizers = []' \
    | kubectl replace --raw "/api/v1/namespaces/${ns}/finalize" -f - >/dev/null 2>&1 || true
  sleep 3

  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    echo "    WARNING: namespace/$ns is still present. Something inside it may still exist:"
    echo "      kubectl get all -n $ns"
  else
    echo "    done (forced)"
  fi
}

if ! minikube status -p "$PROFILE" >/dev/null 2>&1; then
  echo "Minikube profile '$PROFILE' isn't running -- nothing to clean up inside the cluster."
else
  echo "--- Deleting the platform ApplicationSet (owns every enabled component) ---"
  if kubectl -n argocd get applicationset platform >/dev/null 2>&1; then
    kubectl -n argocd delete applicationset platform --wait=true --timeout=300s || \
      echo "  ApplicationSet delete didn't finish cleanly; its Applications will be swept next anyway."
  else
    echo "  not found, skipping"
  fi

  echo ""
  echo "--- Sweeping any remaining Applications ---"
  echo "(covers ones created before a finalizer existed, applied manually, or left by a"
  echo " stuck ApplicationSet delete above)"
  # Portable stand-in for `mapfile` (bash 4+ only) -- macOS ships bash 3.2
  # by default, so this platform's scripts stick to constructs that work
  # there too.
  remaining="$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  if [ -z "$remaining" ]; then
    echo "  none left"
  else
    while IFS= read -r name; do
      [ -n "$name" ] && delete_with_fallback "$name"
    done <<< "$remaining"
  fi

  echo ""
  echo "--- Uninstalling Argo CD ---"
  helm uninstall argocd -n argocd 2>/dev/null || echo "  not installed via helm, skipping"

  # Everything from here down does NOT depend on Argo CD tracking these
  # resources correctly -- it force-deletes by namespace/label directly, so
  # it still works even if an Application was already detached from Argo CD
  # by a manual `kubectl delete` at some point (that leaves the underlying
  # pods/deployments running with nothing left to cascade-delete them).
  echo ""
  echo "--- Deleting component namespaces (this actually waits, unlike a fire-and-forget delete) ---"
  # [[:space:]] instead of \s: BSD grep on stock macOS doesn't support \s.
  namespaces="$(grep -E '^[[:space:]]*name:' "$SCRIPT_DIR/gitops/namespaces.yaml" | awk '{print $2}')"
  for ns in $namespaces argocd; do
    force_delete_namespace "$ns"
  done

  echo ""
  echo "--- Sweeping cluster-scoped leftovers (ClusterRoles, webhooks, CRDs) ---"
  echo "(these live outside any namespace, so deleting namespaces above doesn't touch them)"
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/scripts/lib-components.sh"
  component_names="$(printf '%s\n' "$COMPONENT_TABLE" | awk -F'|' 'NF>1{print $1}')"
  for kind in clusterrole clusterrolebinding validatingwebhookconfiguration mutatingwebhookconfiguration crd; do
    tagged="$(kubectl get "$kind" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}{end}' 2>/dev/null || true)"
    [ -z "$tagged" ] && continue
    while IFS=$'\t' read -r res_name tracking_id; do
      [ -z "$res_name" ] && continue
      [ -z "$tracking_id" ] && continue
      for comp in $component_names; do
        case "$tracking_id" in
          "$comp":*)
            echo "  deleting $kind/$res_name (was tracked by Application '$comp')"
            kubectl delete "$kind" "$res_name" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
            break
            ;;
        esac
      done
    done <<< "$tagged"
  done

  if [ "$KEEP_MINIKUBE" -eq 1 ]; then
    echo ""
    echo "--- Removing foundational CRDs (Gateway API, VolumeSnapshot) ---"
    if [ -f "$SCRIPT_DIR/versions.env" ]; then
      set -a
      # shellcheck disable=SC1091
      source "$SCRIPT_DIR/versions.env"
      set +a
    fi
    GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.1.0}"
    SNAPSHOTTER_VERSION="${SNAPSHOTTER_VERSION:-v8.0.1}"

    kubectl delete -f "$SCRIPT_DIR/gitops/gatewayclasses.yaml" --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml" --ignore-not-found=true 2>/dev/null || true

    SNAPSHOTTER_BASE="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}"
    kubectl delete -f "${SNAPSHOTTER_BASE}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml" --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f "${SNAPSHOTTER_BASE}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml" --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f "${SNAPSHOTTER_BASE}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml" --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f "${SNAPSHOTTER_BASE}/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml" --ignore-not-found=true 2>/dev/null || true
    kubectl delete -f "${SNAPSHOTTER_BASE}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml" --ignore-not-found=true 2>/dev/null || true
  fi
fi

if [ "$KEEP_MINIKUBE" -eq 1 ]; then
  echo ""
  echo "Done. Minikube profile '$PROFILE' left running (--keep-minikube)."
  echo "Re-run ./bootstrap.sh to reinstall everything into it."
else
  echo ""
  echo "--- Deleting Minikube profile '$PROFILE' ---"
  minikube delete -p "$PROFILE" || echo "  (nothing to delete, or already gone)"
  echo ""
  echo "Done. Nothing left -- re-run ./bootstrap.sh to start completely fresh."
fi
