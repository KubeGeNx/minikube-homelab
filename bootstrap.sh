#!/usr/bin/env bash
# Bootstraps a Minikube homelab platform: Minikube -> foundational CRDs ->
# Argo CD -> the platform ApplicationSet (parent resource that creates one
# child Application per component enabled in components.env).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== [1/5] Checking prerequisites ==="
bash scripts/00-prereqs.sh

echo "=== [2/5] Starting Minikube ==="
bash scripts/01-minikube.sh

echo "=== [3/5] Installing foundational CRDs (Gateway API, VolumeSnapshot) ==="
bash scripts/02-foundational-crds.sh

echo "=== [4/5] Installing Argo CD ==="
bash scripts/03-argocd.sh

echo "=== [5/5] Applying namespaces + the platform ApplicationSet ==="
bash scripts/04-apply-apps.sh

cat <<'EOF'

============================================================
 Bootstrap complete.

 Watch components come up:
   kubectl get applications -n argocd
   kubectl get pods -A

 Argo CD admin password:
   kubectl -n argocd get secret argocd-initial-admin-secret \
     -o jsonpath='{.data.password}' | base64 -d; echo

 In a separate terminal, keep this running so LoadBalancer
 services (the shared Envoy Gateway) get IPs:
   minikube tunnel

 Then wire up *.lab.local hostnames and open the UIs over TLS:
   make hosts        # prints the /etc/hosts line
   https://argocd.lab.local      https://grafana.lab.local
   https://prometheus.lab.local  https://minio.lab.local
   https://tempo.lab.local

 Install individual components (deps resolved automatically):
   make velero       # also installs minio
   make alloy        # also installs kube-prometheus-stack, loki, tempo

 See README.md for the full component list, sync-wave order,
 and optional add-ons (MetalLB, OLM, Kubeflow, Cilium CNI).
============================================================
EOF
