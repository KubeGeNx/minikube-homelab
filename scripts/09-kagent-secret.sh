#!/usr/bin/env bash
# Creates the LLM provider API key secret kagent expects. Run before (or
# right after) enabling KAGENT_ENABLED:
#   KAGENT_PROVIDER_API_KEY=sk-... ./scripts/09-kagent-secret.sh
set -euo pipefail

NAMESPACE="${KAGENT_NAMESPACE:-kagent}"
KEY="${KAGENT_PROVIDER_API_KEY:-}"

if [ -z "$KEY" ]; then
  echo "ERROR: set KAGENT_PROVIDER_API_KEY (your LLM provider API key), e.g.:"
  echo "  KAGENT_PROVIDER_API_KEY=sk-... $0"
  exit 1
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$NAMESPACE" create secret generic kagent-model-provider \
  --from-literal=OPENAI_API_KEY="$KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Secret 'kagent-model-provider' created/updated in namespace '$NAMESPACE'."
