#!/usr/bin/env bash
# Applies the shared TLS'd Gateway layer: ClusterIssuers + wildcard cert +
# Gateway (gitops/platform/), then one HTTPRoute per enabled component
# (gitops/platform/routes/). Called by scripts/04-apply-apps.sh once
# cert-manager and envoy-gateway are Healthy; safe to re-run standalone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV="${ENV:-dev}"
bash "$SCRIPT_DIR/build-applicationset.sh" --check
PLAN_FILE="$ROOT_DIR/gitops/rendered/$ENV/platform-plan.json"
plan_enabled() { jq -e --arg id "$1" '.enabled | index($id) != null' "$PLAN_FILE" >/dev/null; }
if ! kubectl get crd clusterissuers.cert-manager.io >/dev/null 2>&1; then
  echo "cert-manager CRDs not present yet -- skipping Gateway/TLS layer."
  echo "Re-run ./scripts/04-apply-apps.sh once cert-manager is Healthy."
  exit 0
fi

echo "Applying ClusterIssuers (SelfSigned -> homelab CA)..."
kubectl apply -f "$ROOT_DIR/gitops/platform/cluster-issuers.yaml"

echo "Applying shared platform Gateway + *.lab.local wildcard Certificate..."
kubectl apply -f "$ROOT_DIR/gitops/platform/gateway.yaml"


# --- Admission policy for AI/agent workloads ---
# Audit mode by default: reports, no blocking. `kubectl get clusterpolicyreport`
# shows violations. Flip validationFailureAction to Enforce in
# gitops/policies/ai-workload-policies.yaml once those reports are clean.
if plan_enabled kyverno; then
  if kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
    echo "Applying AI-workload ClusterPolicies (Audit mode)..."
    kubectl apply -f "$ROOT_DIR/gitops/policies/ai-workload-policies.yaml"
  else
    echo "Kyverno enabled but its CRDs aren't registered yet -- skipping policies."
    echo "  Re-run this script once 'kubectl get pods -n kyverno' is Ready."
  fi
else
  kubectl delete -f "$ROOT_DIR/gitops/policies/ai-workload-policies.yaml" --ignore-not-found >/dev/null 2>&1 || true
fi

echo "Applying HTTPRoutes for enabled components..."
while IFS=$'\t' read -r file enabled; do
  if [ "$enabled" = "true" ]; then
    kubectl apply -f "$ROOT_DIR/gitops/platform/routes/$file"
    echo "  httproute: $file"
  else
    kubectl delete -f "$ROOT_DIR/gitops/platform/routes/$file" --ignore-not-found >/dev/null 2>&1 || true
  fi
done < <(jq -r '.routes[] | [.file, (.enabled|tostring)] | @tsv' "$PLAN_FILE")

cat <<'EOF'

Add these to /etc/hosts (or your internal DNS), pointing at the Gateway IP.
With the docker driver, run `minikube tunnel` in another terminal first,
then:

  GATEWAY_IP=$(kubectl -n envoy-gateway-system get gateway platform \
    -o jsonpath='{.status.addresses[0].value}')
  echo "$GATEWAY_IP argocd.lab.local grafana.lab.local prometheus.lab.local seaweedfs.lab.local tempo.lab.local rabbitmq.lab.local" \
    | sudo tee -a /etc/hosts

(or use `make hosts`). The TLS chain is signed by the self-signed
"homelab-root-ca" -- expect browser warnings, or trust the CA:
  kubectl -n cert-manager get secret homelab-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt
EOF
