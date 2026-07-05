#!/usr/bin/env bash
set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-homelab}"
CPUS="${MINIKUBE_CPUS:-6}"
MEMORY="${MINIKUBE_MEMORY:-36000mb}"
DRIVER="${MINIKUBE_DRIVER:-docker}"
K8S_VERSION="${MINIKUBE_K8S_VERSION:-stable}"
CONTAINER_RUNTIME="${MINIKUBE_CONTAINER_RUNTIME:-docker}"
# CNI: "auto" keeps minikube's default. Set MINIKUBE_CNI=cilium (or calico)
# for a real CNI -- minikube installs it itself via --cni. NOTE: the CNI is
# fixed at cluster creation; changing it means `minikube delete -p homelab`
# and re-bootstrapping.
CNI="${MINIKUBE_CNI:-auto}"

# With the docker driver, minikube's VM memory ceiling is whatever Docker
# Desktop itself is allocated (Settings -> Resources -> Advanced -> Memory),
# not the host's physical RAM. Check that up front with a clear fix instead
# of letting minikube fail with a generic MK_USAGE error.
# Normalize MINIKUBE_MEMORY to plain megabytes for the comparison below.
# Accepts the formats minikube itself accepts: 36000, 36000mb, 36g, 36gb
# (case-insensitive). Returns empty if it can't parse, in which case the
# pre-check is skipped and minikube start does its own validation.
to_mb() {
  local v
  v="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    *gb) v="${v%gb}"; [ -n "$v" ] && [ -z "${v//[0-9]/}" ] && echo $((v * 1024)) ;;
    *g)  v="${v%g}";  [ -n "$v" ] && [ -z "${v//[0-9]/}" ] && echo $((v * 1024)) ;;
    *mb) v="${v%mb}"; [ -n "$v" ] && [ -z "${v//[0-9]/}" ] && echo "$v" ;;
    *)   [ -n "$v" ] && [ -z "${v//[0-9]/}" ] && echo "$v" ;;
  esac
  return 0
}

if [ "$DRIVER" = "docker" ] && command -v docker >/dev/null 2>&1; then
  docker_mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
  docker_mem_mb=$((docker_mem_bytes / 1024 / 1024))
  requested_mb="$(to_mb "$MEMORY")"
  if [ -z "$requested_mb" ]; then
    echo "NOTE: couldn't parse MINIKUBE_MEMORY='$MEMORY' for the Docker memory pre-check; skipping it."
    requested_mb=0
  fi
  if [ "$docker_mem_mb" -gt 0 ] && [ "$requested_mb" -gt "$docker_mem_mb" ]; then
    echo "ERROR: Docker Desktop is only allocated ${docker_mem_mb}MB, but this profile"
    echo "requests --memory=${MEMORY}."
    echo ""
    echo "Fix: Docker Desktop -> Settings -> Resources -> Advanced -> raise the Memory"
    echo "slider to at least ${requested_mb}MB (leave some headroom for macOS itself),"
    echo "then Apply & Restart, and re-run ./bootstrap.sh."
    echo ""
    echo "Or, to proceed now with less: MINIKUBE_MEMORY=$((docker_mem_mb - 512))mb ./bootstrap.sh"
    echo "(the homelab stack is heavy -- kube-prometheus-stack + Loki + Velero"
    echo "want real headroom, so treat a low-memory run as a smoke test,"
    echo "not the full stack)."
    exit 1
  fi
fi

if minikube status -p "$PROFILE" >/dev/null 2>&1; then
  echo "Minikube profile '$PROFILE' already running, skipping start."
else
  echo "Starting Minikube profile '$PROFILE' (cpus=$CPUS memory=$MEMORY driver=$DRIVER runtime=$CONTAINER_RUNTIME)..."
  cni_flag=""
  [ "$CNI" != "auto" ] && cni_flag="--cni=$CNI"
  # shellcheck disable=SC2086
  minikube start \
    -p "$PROFILE" \
    --driver="$DRIVER" \
    --container-runtime="$CONTAINER_RUNTIME" \
    --cpus="$CPUS" \
    --memory="$MEMORY" \
    --kubernetes-version="$K8S_VERSION" \
    --disk-size=60g \
    $cni_flag
fi

kubectl config use-context "$PROFILE"

echo "Enabling addons: metrics-server, storage-provisioner, default-storageclass..."
minikube -p "$PROFILE" addons enable metrics-server
minikube -p "$PROFILE" addons enable storage-provisioner
minikube -p "$PROFILE" addons enable default-storageclass


echo "Waiting for node to be Ready..."
kubectl wait --for=condition=Ready node --all --timeout=180s

kubectl get nodes -o wide
