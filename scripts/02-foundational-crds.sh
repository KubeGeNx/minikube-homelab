#!/usr/bin/env bash
# Installs cluster-wide CRDs that other components assume already exist.
# These are applied directly (not via Argo CD Applications) because they are
# prerequisites at admission time for apps that sync in later waves.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# GATEWAY_API_VERSION and SNAPSHOTTER_VERSION come from versions.env, the
# single source of truth for every component version in this platform.
set -a
# shellcheck disable=SC1091
source "$ROOT_DIR/versions.env"
set +a

echo "--- Gateway API CRDs ($GATEWAY_API_VERSION, experimental channel: adds TCPRoute/TLSRoute/UDPRoute/GRPCRoute) ---"
# Gateway API's CRDs have huge OpenAPI schemas. A normal client-side
# `kubectl apply` stores the whole previous config in the
# kubectl.kubernetes.io/last-applied-configuration annotation, which blows
# past Kubernetes' 262144-byte annotation size limit ("metadata.annotations:
# Too long"). Server-side apply doesn't use that annotation at all (it uses
# managed fields instead), which is the fix the Gateway API project itself
# recommends for this exact error.
kubectl apply --server-side --force-conflicts -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"

# kubectl apply returning doesn't guarantee the API server has finished
# registering the CRD's REST endpoint yet -- anything that applies a
# GatewayClass/HTTPRoute/etc. right after this can hit "no matches for
# kind X" if it runs before that finishes. Wait for it explicitly.
echo "Waiting for Gateway API CRDs to be Established..."
for crd in gatewayclasses.gateway.networking.k8s.io gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io; do
  kubectl wait --for=condition=Established "crd/${crd}" --timeout=60s || \
    echo "  WARNING: ${crd} didn't report Established in time; continuing anyway"
done

echo "--- CSI VolumeSnapshot CRDs ($SNAPSHOTTER_VERSION) ---"
BASE="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/${SNAPSHOTTER_VERSION}"
kubectl apply --server-side --force-conflicts -f "${BASE}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml"
kubectl apply --server-side --force-conflicts -f "${BASE}/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml"
kubectl apply --server-side --force-conflicts -f "${BASE}/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml"

echo "--- CSI Snapshot Controller ---"
kubectl apply -f "${BASE}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml"
kubectl apply -f "${BASE}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml"

echo "Waiting for snapshot-controller to be ready..."
kubectl -n kube-system rollout status deployment/snapshot-controller --timeout=180s || \
  echo "  (snapshot-controller not up yet, Argo CD-managed CSI drivers may still be initializing storage; continuing)"

echo "Foundational CRDs installed."
