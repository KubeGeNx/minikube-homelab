#!/usr/bin/env bash
# End-to-end smoke test for the agentgateway component using the official
# sample app (https://agentgateway.dev/docs/kubernetes/latest/install/sample-app/):
# applies examples/agentgateway-httpbin-sample.yaml, waits for the proxy and
# httpbin to be ready, then curls /headers through a port-forward and checks
# for HTTP 200. Add --keep to leave the sample resources running.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SAMPLE="$ROOT_DIR/examples/agentgateway-httpbin-sample.yaml"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

echo "--- Checking the agentgateway control plane is running ---"
if ! kubectl -n agentgateway-system rollout status deployment/agentgateway --timeout=120s; then
  echo "ERROR: agentgateway control plane not ready. Install it first: make agentgateway"
  exit 1
fi
kubectl get gatewayclass agentgateway

echo "--- Applying the sample (Gateway + httpbin + HTTPRoute) ---"
kubectl apply -f "$SAMPLE"

echo "--- Waiting for the proxy and httpbin to come up ---"
# The control plane creates the proxy Deployment shortly after the Gateway.
for i in $(seq 1 30); do
  kubectl -n agentgateway-system get deployment/agentgateway-proxy >/dev/null 2>&1 && break
  sleep 2
done
kubectl -n agentgateway-system rollout status deployment/agentgateway-proxy --timeout=180s
kubectl -n httpbin rollout status deployment/httpbin --timeout=180s

echo "--- Sending a test request through the gateway ---"
kubectl -n agentgateway-system port-forward deployment/agentgateway-proxy 18080:80 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
sleep 3

STATUS="$(curl -s -o /tmp/agentgateway-sample-response.json -w '%{http_code}' \
  http://localhost:18080/headers -H "host: www.example.com" || true)"

echo "HTTP status: $STATUS"
if [ "$STATUS" = "200" ]; then
  echo "Response body:"
  cat /tmp/agentgateway-sample-response.json
  echo ""
  echo "SUCCESS: agentgateway routed www.example.com -> httpbin."
else
  echo "FAILED: expected 200. Debug with:"
  echo "  kubectl -n agentgateway-system logs deploy/agentgateway"
  echo "  kubectl -n agentgateway-system logs deploy/agentgateway-proxy"
  echo "  kubectl -n httpbin get httproute httpbin -o yaml"
  exit 1
fi

if [ "$KEEP" -eq 1 ]; then
  echo "--keep: leaving the sample resources in place."
  echo "Admin UI: kubectl -n agentgateway-system port-forward deployment/agentgateway-proxy 15000  ->  http://localhost:15000/ui/"
else
  echo "--- Cleaning up the sample resources ---"
  kubectl delete -f "$SAMPLE" --ignore-not-found
fi
