#!/usr/bin/env bash
# Applies MetalLB's IPAddressPool + L2Advertisement, deriving the pool from
# the minikube node subnet (e.g. node 192.168.49.2 -> pool .240-.250).
# Called by scripts/04-apply-apps.sh once the metallb Application is
# Healthy. NOTE: with the docker driver on macOS these IPs are only
# reachable inside Docker's network; `minikube tunnel` remains the
# practical access path there.
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-homelab}"
NODE_IP="$(minikube -p "$PROFILE" ip)"
SUBNET="${NODE_IP%.*}"
POOL_START="${METALLB_POOL_START:-${SUBNET}.240}"
POOL_END="${METALLB_POOL_END:-${SUBNET}.250}"

echo "Configuring MetalLB pool ${POOL_START}-${POOL_END} (node IP: ${NODE_IP})..."
kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
  namespace: metallb-system
spec:
  addresses:
    - ${POOL_START}-${POOL_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - homelab-pool
EOF
