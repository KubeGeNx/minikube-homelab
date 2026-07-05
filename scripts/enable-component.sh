#!/usr/bin/env bash
# Enables one or more components (plus their dependencies, recursively) in
# components.env, then rebuilds/applies the platform via 04-apply-apps.sh.
# Used by the Makefile's per-component targets:
#   ./scripts/enable-component.sh velero    # also enables minio
# Add --no-apply to only flip the flags.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$ROOT_DIR/components.env"

# component -> components.env flag (Helm components come from
# lib-components.sh's table; kubeflow/olm are the special non-Helm ones).
flag_of() {
  case "$1" in
    kubeflow) echo "KUBEFLOW_ENABLED" ;;
    olm)      echo "OLM_ENABLED" ;;
    *)
      # shellcheck disable=SC1091
      source "$SCRIPT_DIR/lib-components.sh"
      printf '%s\n' "$COMPONENT_TABLE" | awk -F'|' -v c="$1" '$1==c{print $2}'
      ;;
  esac
}

# component -> hard dependencies (installed even if not asked for)
deps_of() {
  case "$1" in
    envoy-gateway) echo "cert-manager" ;;                          # TLS'd Gateway needs the CA issuer
    loki-stack)    echo "kube-prometheus-stack" ;;                 # Grafana datasource lives there
    tempo)         echo "kube-prometheus-stack" ;;                 # same
    alloy)         echo "kube-prometheus-stack loki-stack tempo" ;; # forwards to all three
    velero)        echo "minio" ;;                                 # S3 backup target
    *)             echo "" ;;
  esac
}

enable_flag() {
  local var="$1"
  if grep -q "^${var}=" "$ENV_FILE"; then
    # -i.bak + rm: portable across BSD (macOS) and GNU sed
    sed -i.bak "s/^${var}=.*/${var}=true/" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
  else
    printf '\n%s=true\n' "$var" >> "$ENV_FILE"
  fi
  echo "  ${var}=true"
}

RESOLVED=""
resolve() {
  local comp="$1" dep
  case " $RESOLVED " in *" $comp "*) return ;; esac
  for dep in $(deps_of "$comp"); do resolve "$dep"; done
  RESOLVED="$RESOLVED $comp"
}

APPLY=true
COMPONENTS=""
for arg in "$@"; do
  case "$arg" in
    --no-apply) APPLY=false ;;
    *) COMPONENTS="$COMPONENTS $arg" ;;
  esac
done
[ -n "${COMPONENTS// /}" ] || { echo "Usage: $0 [--no-apply] <component>..."; exit 1; }

for comp in $COMPONENTS; do
  flag="$(flag_of "$comp")"
  [ -n "$flag" ] || { echo "ERROR: unknown component '$comp'"; exit 1; }
  resolve "$comp"
done

echo "Enabling (with dependencies):$RESOLVED"
for comp in $RESOLVED; do
  enable_flag "$(flag_of "$comp")"
done

if [ "$APPLY" = "true" ]; then
  echo ""
  bash "$SCRIPT_DIR/04-apply-apps.sh"
fi
