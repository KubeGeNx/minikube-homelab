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

# Register Docker Hub's envoyproxy org as a Helm OCI repository. Without
# this, Argo CD resolves oci://docker.io/envoyproxy + chart gateway-helm
# incorrectly (queries /v2/envoyproxy/manifests/<tag> -> 401) because
# anonymous OCI against Docker Hub needs the repo declared with enableOCI
# so the token handshake + chart-path composition go through Argo's Helm
# OCI client.
echo "Registering oci://docker.io/envoyproxy as a Helm OCI repository..."
kubectl apply -f - <<'REPOEOF'
apiVersion: v1
kind: Secret
metadata:
  name: repo-envoyproxy-oci
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  name: envoyproxy-oci
  type: helm
  url: docker.io/envoyproxy
  enableOCI: "true"
REPOEOF

# Same deal for agentgateway's OCI registry (used by
# gitops/apps/17-agentgateway-crds.yaml and 18-agentgateway.yaml).
echo "Registering oci://cr.agentgateway.dev/charts as a Helm OCI repository..."
kubectl apply -f - <<'REPOEOF'
apiVersion: v1
kind: Secret
metadata:
  name: repo-agentgateway-oci
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  name: agentgateway-oci
  type: helm
  url: cr.agentgateway.dev/charts
  enableOCI: "true"
REPOEOF

echo "Argo CD installed."
echo "Admin password:"
echo "  kubectl -n $NAMESPACE get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
