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
# ENV selects the environment overlay (environments/<env>/). One environment
# per cluster; "dev" is the minikube profile of the same architecture.
# Exported so build-applicationset.sh and 08-platform-gateway.sh resolve the
# same overlay this script did.
export ENV="${ENV:-dev}"
if [ ! -d "$ROOT_DIR/environments/$ENV" ]; then
  echo "ERROR: unknown environment '$ENV' -- $ROOT_DIR/environments/$ENV does not exist."
  exit 1
fi
APPLICATIONSET_FILE="$ROOT_DIR/gitops/rendered/$ENV/applicationset.yaml"
PLAN_FILE="$ROOT_DIR/gitops/rendered/$ENV/platform-plan.json"

# Refuse stale generated artifacts before the first cluster mutation. Update
# them deliberately with `ENV=... bash scripts/build-applicationset.sh`.
bash "$SCRIPT_DIR/build-applicationset.sh" --check
plan_enabled() { jq -e --arg id "$1" '.enabled | index($id) != null' "$PLAN_FILE" >/dev/null; }

echo "Applying namespaces for enabled components only..."
echo "(gitops/namespaces.yaml lists every namespace this platform *could* use --"
echo " that's a reference for cleanup.sh, not something applied wholesale here)"
enabled_namespaces="$(jq -r '.namespaces[]' "$PLAN_FILE" | sort -u)"
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

# --- Collector mTLS certificates ---
# THIS MUST RUN BEFORE wait_healthy, and the reason is a deadlock found by
# actually installing: both collector tiers mount otel-{agent,gateway}-tls, so
# their pods sit in ContainerCreating with "secret not found" until these
# Certificates exist. wait_healthy then blocks forever waiting for
# Applications that cannot become Healthy, and the step that creates the
# certificates never gets to run. It does NOT resolve itself.
#
# Only needs cert-manager's CRDs, which is why it can run this early.
if plan_enabled otel-agent && plan_enabled cert-manager; then
  if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
    echo "Preparing the homelab CA before issuing collector certificates..."
    kubectl apply -f "$ROOT_DIR/gitops/platform/cluster-issuers.yaml"
    kubectl -n cert-manager wait --for=condition=Ready certificate/homelab-root-ca --timeout=180s
    kubectl wait --for=condition=Ready clusterissuer/homelab-ca --timeout=60s
    echo "Applying OpenTelemetry collector mTLS Certificates (otel namespace)..."
    kubectl create namespace otel --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl apply -f "$ROOT_DIR/gitops/platform/otel-mtls.yaml"
  else
    echo "cert-manager CRDs not present yet -- collector mTLS certs deferred."
    echo "  The collector pods will wait on their secrets; re-run this script."
  fi
fi

# --- Special install handlers selected by the catalogue plan ---
# Kubeflow uses Argo CD's git source; its existing script renders and applies
# the manifest using version and enablement from the shared plan.
echo ""
echo "--- Special (non-Helm) components ---"
mkdir -p "$ROOT_DIR/gitops/rendered"
if plan_enabled kubeflow; then
  KUBEFLOW_ADAPTER="$(jq -r '.entries.kubeflow.adapter' "$PLAN_FILE")"
  KUBEFLOW_MANIFEST="$(jq -r '.entries.kubeflow.manifest' "$PLAN_FILE")"
  KUBEFLOW_VERSION_KEY="$(jq -r '.entries.kubeflow.version' "$PLAN_FILE")"
  [ "$KUBEFLOW_ADAPTER" = "argocd-git" ] || { echo "ERROR: unsupported Kubeflow adapter '$KUBEFLOW_ADAPTER'" >&2; exit 1; }
  KUBEFLOW_VERSION="$(jq -r --arg key "$KUBEFLOW_VERSION_KEY" '.versions[$key]' "$PLAN_FILE")"
  [ -n "$KUBEFLOW_VERSION" ] && [ "$KUBEFLOW_VERSION" != "null" ] || { echo "ERROR: $KUBEFLOW_VERSION_KEY missing from plan" >&2; exit 1; }
  echo "Kubeflow enabled -- rendering and applying $KUBEFLOW_MANIFEST..."
  export KUBEFLOW_VERSION
  envsubst "\${$KUBEFLOW_VERSION_KEY}" < "$ROOT_DIR/$KUBEFLOW_MANIFEST" > "$ROOT_DIR/gitops/rendered/16-kubeflow.yaml"
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
if plan_enabled olm; then
  echo "OLM enabled -- installing/verifying (scripts/06-olm.sh)..."
  OLM_HANDLER="$(jq -r '.entries.olm.handler' "$PLAN_FILE")"
  bash "$ROOT_DIR/$OLM_HANDLER" install
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
names="$(jq -r '.enabled[] as $id | select(.entries[$id].adapter == "helm") | $id' "$PLAN_FILE")"

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
if plan_enabled metallb; then
  echo ""
  echo "--- Configuring MetalLB address pool (scripts/07-metallb-config.sh) ---"
  bash "$SCRIPT_DIR/07-metallb-config.sh" || \
    echo "  WARNING: MetalLB pool config failed -- re-run ./scripts/07-metallb-config.sh once 'kubectl -n metallb-system get pods' is Ready."
fi

# --- Gateway API exposure + TLS (*.lab.local) ---
# Needs cert-manager's CRDs (ClusterIssuer/Certificate) and the Envoy
# Gateway controller, both confirmed Healthy above.
if plan_enabled envoy-gateway && plan_enabled cert-manager; then
  echo ""
  echo "--- Applying platform Gateway + TLS + HTTPRoutes (scripts/08-platform-gateway.sh) ---"
  bash "$SCRIPT_DIR/08-platform-gateway.sh"
fi

# --- Observability verbosity control (ConfigMap + RBAC + expiry CronJob) ---
# Installs the DEFAULTS only; it never overwrites a live value, so re-running
# this script does not silently disable a capture window someone opened.
if plan_enabled otel-agent; then
  echo ""
  echo "--- Observability level control (scripts/12-observability-level.sh) ---"
  bash "$SCRIPT_DIR/12-observability-level.sh" install ||     echo "  WARNING: level control not installed -- re-run scripts/12-observability-level.sh install"
fi

# --- AI governance rules (cost, refusals, tool failures) ---
# These go into MIMIR's ruler, not Prometheus: the gen_ai_* metrics are pushed
# over OTLP and Prometheus never sees them, so a PrometheusRule would evaluate
# an empty series set and stay green forever. The CronJob in the manifest syncs
# them from a ConfigMap every 15 minutes.
if plan_enabled mimir; then
  echo ""
  echo "--- AI governance rules (Mimir ruler) ---"
  kubectl apply -f "$ROOT_DIR/gitops/platform/ai-governance-rules.yaml"
  echo "  rules sync runs every 15m; force one now with:"
  echo "    kubectl -n mimir create job --from=cronjob/mimir-rules-loader rules-sync-now"
else
  kubectl delete -f "$ROOT_DIR/gitops/platform/ai-governance-rules.yaml" --ignore-not-found >/dev/null 2>&1 || true
fi

echo ""
echo "All Applications (owned by the 'platform' ApplicationSet):"
kubectl get applications -n argocd -l 'platform-wave' 2>/dev/null || kubectl get applications -n argocd

# --- Velero <-> SeaweedFS credential wiring ---
# Velero's Application (gitops/apps/13-velero.yaml) mounts a secret named
# "velero-seaweedfs-credentials" that nothing creates automatically -- Argo CD
# can't generate credentials on its own. Without it, Velero's pods sit in
# ContainerCreating/PodInitializing forever with a FailedMount event
# ("secret ... not found"). This has to run down here, AFTER the
# wait_healthy loop above -- kubectl wait only blocks on pods that already
# exist, it doesn't wait for a pod to be *created*, so running this straight
# after `kubectl apply` on the ApplicationSet (before Argo CD has even
# created SeaweedFS's child Application, let alone scheduled its pod) fails
# fast with nothing to wait on. By this point SeaweedFS's Application has been
# confirmed Healthy, so its pod genuinely exists and is Ready.
if plan_enabled velero && plan_enabled seaweedfs; then
  if kubectl -n velero get secret velero-seaweedfs-credentials >/dev/null 2>&1; then
    echo ""
    echo "Velero's SeaweedFS credentials secret already exists, skipping."
  else
    echo ""
    echo "--- Wiring Velero's SeaweedFS credentials (scripts/05-velero-secret.sh) ---"
    if kubectl -n argocd get application seaweedfs -o jsonpath='{.status.health.status}' 2>/dev/null | grep -q Healthy; then
      bash "$SCRIPT_DIR/05-velero-secret.sh" || \
        echo "  WARNING: couldn't create the secret (see errors above) -- re-run ./scripts/04-apply-apps.sh once 'kubectl -n seaweedfs get pods' shows it Running."
    else
      echo "  SeaweedFS's Application isn't Healthy yet -- skipping for now."
      echo "  Once 'kubectl -n seaweedfs get pods' shows it Running, re-run ./scripts/04-apply-apps.sh (or just ./scripts/05-velero-secret.sh) to create the secret."
    fi
  fi
fi
