#!/usr/bin/env bash
# Applies namespaces, GatewayClasses, and the platform ApplicationSet.
#
# The ApplicationSet (built by scripts/build-applicationset.sh from
# gitops/apps/*.yaml + versions.env + components.env) is the parent: its
# List generator has exactly one element per component that's enabled in
# components.env. Argo CD's own applicationset-controller reconciles the
# set of child Applications to match that list -- creating ones that are
# newly enabled and deleting (cascading, via the resources-finalizer) ones
# that became disabled. Nothing in this script deletes an Application
# itself; that's entirely Argo CD's job now.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
APPLICATIONSET_FILE="$ROOT_DIR/gitops/rendered/applicationset.yaml"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-components.sh"
set -a
# shellcheck disable=SC1090
source "$ROOT_DIR/components.env"
# shellcheck disable=SC1090
source "$ROOT_DIR/versions.env"
set +a

echo "Applying namespaces for enabled components only..."
echo "(gitops/namespaces.yaml lists every namespace this platform *could* use --"
echo " that's a reference for cleanup.sh, not something applied wholesale here)"
enabled_namespaces=""
while IFS='|' read -r app enabled_var file wave; do
  [ -z "$app" ] && continue
  is_component_enabled "$enabled_var" || continue
  ns="$(awk '/^  destination:/{f=1;next} f && /namespace:/{print $2; exit}' "$ROOT_DIR/gitops/apps/$file")"
  [ -n "$ns" ] && enabled_namespaces="$enabled_namespaces $ns"
done <<< "$COMPONENT_TABLE"
# dedupe in case multiple components share a namespace
enabled_namespaces="$(printf '%s\n' $enabled_namespaces | sort -u)"
for ns in $enabled_namespaces; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "  namespace/$ns"
done

# Self-heal: this script is meant to be safe to run standalone (not just as
# part of bootstrap.sh), including after `cleanup.sh --keep-minikube`, which
# removes the Gateway API / VolumeSnapshot CRDs on purpose. Applying
# gitops/gatewayclasses.yaml without those CRDs fails with "no matches for
# kind GatewayClass", so make sure they're actually present first --
# re-running 02-foundational-crds.sh is idempotent (plain `kubectl apply`s)
# and cheap if they're already there.
if ! kubectl get crd gatewayclasses.gateway.networking.k8s.io >/dev/null 2>&1; then
  echo "Gateway API CRDs not found -- installing them first (scripts/02-foundational-crds.sh)..."
  bash "$SCRIPT_DIR/02-foundational-crds.sh"
fi

# Same self-heal for Argo CD: the ApplicationSet CRD is part of Argo CD's
# Helm chart, so applying the rendered ApplicationSet on a cluster where
# Argo CD isn't (yet) installed fails with "no matches for kind
# ApplicationSet". Install it first -- 03-argocd.sh is an idempotent
# `helm upgrade --install`.
if ! kubectl get crd applicationsets.argoproj.io >/dev/null 2>&1; then
  echo "Argo CD (ApplicationSet CRD) not found -- installing it first (scripts/03-argocd.sh)..."
  bash "$SCRIPT_DIR/03-argocd.sh"
fi

echo "Applying GatewayClasses..."
kubectl apply -f "$ROOT_DIR/gitops/gatewayclasses.yaml"

echo "Building platform ApplicationSet from gitops/apps/*.yaml + versions.env + components.env..."
bash "$SCRIPT_DIR/build-applicationset.sh"

echo "Applying platform ApplicationSet (this is the parent that owns every child Application)..."
kubectl apply -f "$APPLICATIONSET_FILE"

# --- Special (non-Helm) components ---
# Kubeflow doesn't fit the ApplicationSet's Helm-chart template (it's a
# git+kustomize bundle), so it's not in scripts/lib-components.sh's
# COMPONENT_TABLE and build-applicationset.py never sees it. Handle it here
# directly: render its ${KUBEFLOW_VERSION} placeholder and apply/delete its
# standalone Application based on KUBEFLOW_ENABLED, same enable/disable
# contract as everything else in components.env.
echo ""
echo "--- Special (non-Helm) components ---"
mkdir -p "$ROOT_DIR/gitops/rendered"
if is_component_enabled "KUBEFLOW_ENABLED"; then
  echo "Kubeflow enabled -- rendering and applying gitops/special/16-kubeflow.yaml..."
  envsubst '$KUBEFLOW_VERSION' < "$ROOT_DIR/gitops/special/16-kubeflow.yaml" > "$ROOT_DIR/gitops/rendered/16-kubeflow.yaml"
  kubectl apply -f "$ROOT_DIR/gitops/rendered/16-kubeflow.yaml"
  echo "Kubeflow's own manifests typically need several sync passes to fully"
  echo "converge (see the comments in gitops/special/16-kubeflow.yaml) -- this"
  echo "won't block the rest of this script, check on it separately with:"
  echo "  kubectl -n argocd get application kubeflow"
else
  if kubectl -n argocd get application kubeflow >/dev/null 2>&1; then
    echo "Kubeflow disabled but still installed -- deleting (cascades to its resources)..."
    kubectl -n argocd delete application kubeflow --wait=true --timeout=180s 2>/dev/null || \
      echo "  didn't finish in time; Argo CD will keep trying, or re-run this script"
  else
    echo "Kubeflow disabled, not installed -- nothing to do"
  fi
fi

# OLM: official release manifests, not Helm (see scripts/06-olm.sh).
if is_component_enabled "OLM_ENABLED"; then
  echo "OLM enabled -- installing/verifying (scripts/06-olm.sh)..."
  bash "$SCRIPT_DIR/06-olm.sh" install
else
  if kubectl get namespace olm >/dev/null 2>&1; then
    echo "OLM disabled but still installed -- uninstalling (scripts/06-olm.sh)..."
    bash "$SCRIPT_DIR/06-olm.sh" uninstall
  else
    echo "OLM disabled, not installed -- nothing to do"
  fi
fi

# Names of the components that should exist right now, for the readiness
# wait below. Note: unlike the old wave-by-wave bash loop, the
# ApplicationSet doesn't stage these -- all enabled components sync
# concurrently, and Helm/Kubernetes' own retry+backoff resolves ordering
# (e.g. a PVC stays Pending until its StorageClass exists, then binds). That's fine for a homelab. If you want Argo CD to enforce strict
# wave ordering natively, look at ApplicationSet's `strategy: RollingSync`
# with steps matching the `platform-wave` label this template sets on every
# generated Application -- not enabled here, but the label is there ready
# for it.
# Plain string list instead of a bash array: expanding an EMPTY array with
# "${names[@]}" under set -u aborts with "unbound variable" on macOS's
# default bash 3.2 (fixed in bash 4.4), and "no enabled Helm components"
# is a legal state here (e.g. everything off except Kubeflow).
names=""
while IFS='|' read -r app enabled_var file wave; do
  [ -z "$app" ] && continue
  if is_component_enabled "$enabled_var"; then
    names="$names $app"
  fi
done <<< "$COMPONENT_TABLE"

wait_healthy() {
  local name="$1" timeout="${2:-300}" elapsed=0
  echo -n "  waiting for '$name' to be Healthy "
  while [ "$elapsed" -lt "$timeout" ]; do
    status="$(kubectl -n argocd get application "$name" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")"
    if [ "$status" = "Healthy" ]; then
      echo "-> Healthy"
      return 0
    fi
    echo -n "."
    sleep 5
    elapsed=$((elapsed + 5))
  done
  echo "-> timed out (last status: ${status:-unknown}); continuing anyway (Argo CD will keep reconciling)"
}

echo ""
echo "Waiting for the ApplicationSet controller to create child Applications..."
sleep 10

echo ""
echo "--- Waiting for enabled components to report Healthy ---"
for name in $names; do
  wait_healthy "$name"
done

# --- MetalLB address pool ---
# The pool CRs need MetalLB's CRDs + webhook, so this runs after the
# wait_healthy loop confirmed the metallb Application is up.
if is_component_enabled "METALLB_ENABLED"; then
  echo ""
  echo "--- Configuring MetalLB address pool (scripts/07-metallb-config.sh) ---"
  bash "$SCRIPT_DIR/07-metallb-config.sh" || \
    echo "  WARNING: MetalLB pool config failed -- re-run ./scripts/07-metallb-config.sh once 'kubectl -n metallb-system get pods' is Ready."
fi

# --- Gateway API exposure + TLS (*.lab.local) ---
# Needs cert-manager's CRDs (ClusterIssuer/Certificate) and the Envoy
# Gateway controller, both confirmed Healthy above.
if is_component_enabled "ENVOY_GATEWAY_ENABLED" && is_component_enabled "CERT_MANAGER_ENABLED"; then
  echo ""
  echo "--- Applying platform Gateway + TLS + HTTPRoutes (scripts/08-platform-gateway.sh) ---"
  bash "$SCRIPT_DIR/08-platform-gateway.sh"
fi

echo ""
echo "All Applications (owned by the 'platform' ApplicationSet):"
kubectl get applications -n argocd -l 'platform-wave' 2>/dev/null || kubectl get applications -n argocd

# --- Velero <-> MinIO credential wiring ---
# Velero's Application (gitops/apps/13-velero.yaml) mounts a secret named
# "velero-minio-credentials" that nothing creates automatically -- Argo CD
# can't generate credentials on its own. Without it, Velero's pods sit in
# ContainerCreating/PodInitializing forever with a FailedMount event
# ("secret ... not found"). This has to run down here, AFTER the
# wait_healthy loop above -- kubectl wait only blocks on pods that already
# exist, it doesn't wait for a pod to be *created*, so running this straight
# after `kubectl apply` on the ApplicationSet (before Argo CD has even
# created MinIO's child Application, let alone scheduled its pod) fails
# fast with nothing to wait on. By this point MinIO's Application has been
# confirmed Healthy, so its pod genuinely exists and is Ready.
if is_component_enabled "VELERO_ENABLED" && is_component_enabled "MINIO_ENABLED"; then
  if kubectl -n velero get secret velero-minio-credentials >/dev/null 2>&1; then
    echo ""
    echo "Velero's MinIO credentials secret already exists, skipping."
  else
    echo ""
    echo "--- Wiring Velero's MinIO credentials (scripts/05-velero-secret.sh) ---"
    if kubectl -n argocd get application minio -o jsonpath='{.status.health.status}' 2>/dev/null | grep -q Healthy; then
      bash "$SCRIPT_DIR/05-velero-secret.sh" || \
        echo "  WARNING: couldn't create the secret (see errors above) -- re-run ./scripts/04-apply-apps.sh once 'kubectl -n minio get pods' shows it Running."
    else
      echo "  MinIO's Application isn't Healthy yet -- skipping for now."
      echo "  Once 'kubectl -n minio get pods' shows it Running, re-run ./scripts/04-apply-apps.sh (or just ./scripts/05-velero-secret.sh) to create the secret."
    fi
  fi
fi
