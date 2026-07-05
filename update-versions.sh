#!/usr/bin/env bash
# Checks every component's Helm chart repo / GitHub releases for the latest
# stable version and updates versions.env -- the single file that controls
# every component version in this platform. Nothing else needs to change:
# gitops/apps/*.yaml already reference ${VAR} placeholders that get
# substituted from versions.env when scripts/build-applicationset.py builds
# the platform ApplicationSet.
#
# NOTE: KUBEFLOW_VERSION is intentionally not checked here -- it's a git
# tag/branch in kubeflow/manifests, not a Helm chart, and doesn't map
# cleanly to either lookup method below. Check
# https://github.com/kubeflow/manifests for new releases manually.
#
# Usage:
#   ./update-versions.sh            # check + update versions.env in place
#   ./update-versions.sh --dry-run  # just print what would change
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_FILE="$SCRIPT_DIR/versions.env"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

for bin in helm curl jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: '$bin' is required. Install it (e.g. brew install $bin) and re-run."
    exit 1
  fi
done

if [ ! -f "$VERSIONS_FILE" ]; then
  echo "ERROR: $VERSIONS_FILE not found."
  exit 1
fi

# One row per component: VAR|TYPE|REPO_ALIAS|REPO_URL|CHART_OR_GH_SLUG
# TYPE is "helm" (Helm chart repo) or "ghrelease" (GitHub releases API).
COMPONENTS='
CERT_MANAGER_VERSION|helm|jetstack|https://charts.jetstack.io|cert-manager
METALLB_VERSION|helm|metallb|https://metallb.github.io/metallb|metallb
EXTERNAL_SECRETS_VERSION|helm|external-secrets|https://charts.external-secrets.io|external-secrets
KUBE_PROMETHEUS_STACK_VERSION|helm|prometheus-community|https://prometheus-community.github.io/helm-charts|kube-prometheus-stack
LOKI_STACK_VERSION|helm|grafana|https://grafana.github.io/helm-charts|loki-stack
TEMPO_CHART_VERSION|helm|grafana|https://grafana.github.io/helm-charts|tempo
ALLOY_CHART_VERSION|helm|grafana|https://grafana.github.io/helm-charts|alloy
MINIO_CHART_VERSION|helm|minio|https://charts.min.io/|minio
VELERO_VERSION|helm|vmware-tanzu|https://vmware-tanzu.github.io/helm-charts|velero
ARGOCD_CHART_VERSION|helm|argo|https://argoproj.github.io/argo-helm|argo-cd
ENVOY_GATEWAY_VERSION|ghrelease|-|-|envoyproxy/gateway
GATEWAY_API_VERSION|ghrelease|-|-|kubernetes-sigs/gateway-api
SNAPSHOTTER_VERSION|ghrelease|-|-|kubernetes-csi/external-snapshotter
KAGENT_VERSION|helm|kagent|https://kagent-dev.github.io/kagent|kagent
OLM_VERSION|ghrelease|-|-|operator-framework/operator-lifecycle-manager
'

current_value() {
  grep -E "^$1=" "$VERSIONS_FILE" | head -n1 | cut -d= -f2-
}

latest_helm_version() {
  local alias="$1" url="$2" chart="$3"
  helm repo add "$alias" "$url" >/dev/null 2>&1 || true
  helm repo update "$alias" >/dev/null 2>&1 || true
  # `helm search repo` matches substrings, so filter to the exact chart
  # name before picking the newest non-prerelease version.
  helm search repo "${alias}/${chart}" --versions -o json 2>/dev/null \
    | jq -r --arg name "${alias}/${chart}" \
        '[.[] | select(.name == $name) | select(.version | test("-") | not)] | .[0].version // empty'
}

latest_gh_version() {
  local slug="$1"
  curl -sf -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${slug}/releases/latest" \
    | jq -r '.tag_name // empty'
}

echo "Checking latest versions..."
printf "%-30s %-15s %-15s\n" "COMPONENT" "CURRENT" "LATEST"
printf "%-30s %-15s %-15s\n" "---------" "-------" "------"

updated=0
tmp_updates="$(mktemp)"
trap 'rm -f "$tmp_updates"' EXIT

while IFS='|' read -r var type alias url slug; do
  [ -z "$var" ] && continue
  current="$(current_value "$var")"

  if [ "$type" = "helm" ]; then
    latest="$(latest_helm_version "$alias" "$url" "$slug" || true)"
  else
    latest="$(latest_gh_version "$slug" || true)"
  fi

  if [ -z "$latest" ]; then
    printf "%-30s %-15s %-15s\n" "$var" "$current" "(lookup failed, skipped)"
    continue
  fi

  printf "%-30s %-15s %-15s\n" "$var" "$current" "$latest"

  if [ "$latest" != "$current" ]; then
    echo "$var=$latest" >> "$tmp_updates"
    updated=$((updated + 1))
  fi
done <<< "$COMPONENTS"

echo ""
if [ "$updated" -eq 0 ]; then
  echo "Everything is already at the latest version. No changes."
  exit 0
fi

echo "$updated component(s) have a newer version available."

if [ "$DRY_RUN" -eq 1 ]; then
  echo "--dry-run: not writing changes to versions.env."
  exit 0
fi

# Apply each changed KEY=VALUE into versions.env, preserving comments,
# ordering, and every untouched line exactly as-is.
while IFS='=' read -r key val; do
  [ -z "$key" ] && continue
  awk -v k="$key" -v v="$val" 'BEGIN{FS=OFS="="} $1==k{$2=v} {print}' \
    "$VERSIONS_FILE" > "${VERSIONS_FILE}.tmp"
  mv "${VERSIONS_FILE}.tmp" "$VERSIONS_FILE"
done < "$tmp_updates"

echo "versions.env updated. Review with: git diff versions.env"
echo "Then apply: ./bootstrap.sh   (or just: ./scripts/04-apply-apps.sh if the cluster already exists)"
