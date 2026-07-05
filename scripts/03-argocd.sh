#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# ARGOCD_CHART_VERSION comes from versions.env, the single source of truth
# for every component version in this platform.
set -a
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"
set +a

NAMESPACE="argocd"
CHART_VERSION="$ARGOCD_CHART_VERSION"

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo update argo >/dev/null

echo "Installing Argo CD ($CHART_VERSION) into namespace '$NAMESPACE'..."
helm upgrade --install argocd argo/argo-cd \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set configs.params."server\.insecure"=true \
  --wait --timeout 10m

echo "Waiting for argocd-server rollout..."
kubectl -n "$NAMESPACE" rollout status deployment/argocd-server --timeout=300s

echo "Argo CD installed."
echo "Admin password:"
echo "  kubectl -n $NAMESPACE get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
