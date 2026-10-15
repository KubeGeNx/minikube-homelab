#!/usr/bin/env bash
# Creates the secret the genai-agent sample reads when FAKE_LLM=false.
#
#   ANTHROPIC_API_KEY=sk-ant-... ./scripts/13-genai-agent-secret.sh
#
# The sample defaults to FAKE_LLM=true and needs none of this -- run it only
# when you actually want real model calls. Mirrors scripts/09-kagent-secret.sh.
#
# NOTE: this creates a plain Kubernetes Secret, which is base64, not
# encryption. Above dev, source it from a real vault through External Secrets
# Operator (already in the repo, enabled in the staging/prod overlays) instead
# of running this script.
set -euo pipefail

NAMESPACE="${NAMESPACE:-default}"
SECRET_NAME=genai-agent-model-provider

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  cat <<'USAGE'
ERROR: ANTHROPIC_API_KEY is not set.

  ANTHROPIC_API_KEY=sk-ant-... ./scripts/13-genai-agent-secret.sh

Then switch the sample to real calls:
  kubectl -n default set env deployment/genai-agent FAKE_LLM=false
USAGE
  exit 1
fi

case "$ANTHROPIC_API_KEY" in
  sk-ant-*) ;;
  *) echo "WARNING: key does not start with 'sk-ant-' -- continuing anyway." ;;
esac

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Created $NAMESPACE/$SECRET_NAME."
echo "Switch the sample to real calls with:"
echo "  kubectl -n $NAMESPACE set env deployment/genai-agent FAKE_LLM=false"
