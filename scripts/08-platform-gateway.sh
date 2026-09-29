#!/usr/bin/env bash
# Applies the shared TLS'd Gateway layer: ClusterIssuers + wildcard cert +
# Gateway (gitops/platform/), then one HTTPRoute per enabled component
# (gitops/platform/routes/). Called by scripts/04-apply-apps.sh once
# cert-manager and envoy-gateway are Healthy; safe to re-run standalone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-components.sh"
ENV="${ENV:-dev}"
set -a
# shellcheck disable=SC1090
source "$ROOT_DIR/components.env"
# Environment overlay on top of the base, matching build-applicationset.py's
# layering -- otherwise a component disabled only in this environment would
# still get an HTTPRoute applied for it.
if [ -f "$ROOT_DIR/environments/$ENV/components.env" ]; then
  # shellcheck disable=SC1090
  source "$ROOT_DIR/environments/$ENV/components.env"
fi
set +a

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
if is_component_enabled "KYVERNO_ENABLED"; then
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

# route file -> flag guarding it (route is applied only when its backend
# component is enabled; argocd is always installed by bootstrap).
apply_route() {
  local file="$1" flag="$2"
  if [ "$flag" = "-" ] || is_component_enabled "$flag"; then
    kubectl apply -f "$ROOT_DIR/gitops/platform/routes/${file}"
    echo "  httproute: ${file}"
  else
    kubectl delete -f "$ROOT_DIR/gitops/platform/routes/${file}" --ignore-not-found >/dev/null 2>&1 || true
  fi
}
echo "Applying HTTPRoutes for enabled components..."
apply_route argocd.yaml     -
apply_route grafana.yaml    KUBE_PROMETHEUS_STACK_ENABLED
apply_route prometheus.yaml KUBE_PROMETHEUS_STACK_ENABLED
apply_route minio.yaml      MINIO_ENABLED
apply_route tempo.yaml      TEMPO_ENABLED
apply_route rabbitmq.yaml   RABBITMQ_ENABLED

cat <<'EOF'

Add these to /etc/hosts (or your internal DNS), pointing at the Gateway IP.
With the docker driver, run `minikube tunnel` in another terminal first,
then:

  GATEWAY_IP=$(kubectl -n envoy-gateway-system get gateway platform \
    -o jsonpath='{.status.addresses[0].value}')
  echo "$GATEWAY_IP argocd.lab.local grafana.lab.local prometheus.lab.local minio.lab.local tempo.lab.local rabbitmq.lab.local" \
    | sudo tee -a /etc/hosts

(or use `make hosts`). The TLS chain is signed by the self-signed
"homelab-root-ca" -- expect browser warnings, or trust the CA:
  kubectl -n cert-manager get secret homelab-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > homelab-ca.crt
EOF
