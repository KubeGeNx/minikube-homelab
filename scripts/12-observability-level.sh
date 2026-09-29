#!/usr/bin/env bash
# Runtime verbosity control for the observability stack.
#
#   ./scripts/12-observability-level.sh install
#   ./scripts/12-observability-level.sh status
#   ./scripts/12-observability-level.sh level debug|normal
#   ./scripts/12-observability-level.sh capture on [--ttl 30m]
#   ./scripts/12-observability-level.sh capture off
#
# WHY A SCRIPT AND NOT `kubectl edit`:
#
# The collector reads these values through ${env:VAR} expansion, which happens
# ONCE at process start. The Helm chart's config-checksum annotation covers
# only its own ConfigMap, not the external one referenced via extraEnvsFrom --
# so editing observability-levels rolls precisely nothing, and the change
# appears to have silently failed. Every path in this script therefore ends in
# an explicit rollout restart of the readers.
#
# Content capture is time-boxed. `capture on` stamps an expiry and the CronJob
# in gitops/platform/observability-levels.yaml turns it back off. There is no
# "on indefinitely" option, on purpose.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
MANIFEST="$ROOT_DIR/gitops/platform/observability-levels.yaml"

# Namespaces that get a copy of the ConfigMap. `otel` holds the collector
# tiers; the rest are where instrumented applications run.
OBS_NAMESPACES="${OBS_NAMESPACES:-otel default}"

CM=observability-levels
# Deployments/DaemonSets/StatefulSets carrying this label get restarted on
# every change. Both collector tiers are matched by name below regardless.
APP_SELECTOR="observability.lab.local/managed=true"

die() { echo "ERROR: $*" >&2; exit 1; }

require_cluster() {
  kubectl cluster-info >/dev/null 2>&1 || die "no reachable cluster (is minikube running?)"
}

# Duration like 30m / 2h / 45s -> seconds. Deliberately strict: a typo here
# would otherwise produce a nonsense expiry and leave capture on far too long.
ttl_to_seconds() {
  local ttl="$1" num unit
  num="${ttl%[smh]}"
  unit="${ttl##*[0-9]}"
  case "$num" in ''|*[!0-9]*) die "bad --ttl '$ttl' (expected e.g. 30m, 2h, 90s)" ;; esac
  case "$unit" in
    s) echo "$num" ;;
    m) echo $((num * 60)) ;;
    h) echo $((num * 3600)) ;;
    *) die "bad --ttl '$ttl' (unit must be s, m or h)" ;;
  esac
}

# RFC3339 UTC, now + N seconds. BSD date (macOS) and GNU date disagree on
# relative-time flags, so handle both rather than assuming the runner's OS.
future_rfc3339() {
  local secs="$1"
  date -u -v "+${secs}S" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "+${secs} seconds" +%Y-%m-%dT%H:%M:%SZ
}

existing_namespaces() {
  local ns out=""
  for ns in $OBS_NAMESPACES; do
    kubectl get namespace "$ns" >/dev/null 2>&1 && out="$out $ns"
  done
  echo "$out"
}

# The step everyone forgets. Without it the ConfigMap says one thing and the
# running processes keep doing another.
restart_readers() {
  local ns
  echo "Restarting readers (env expansion only happens at process start)..."
  for ns in $(existing_namespaces); do
    if [ "$ns" = "otel" ]; then
      # Gateway last: restarting it drops in-flight tail-sampling decision
      # windows, so let the agents settle first.
      kubectl -n otel rollout restart daemonset -l app.kubernetes.io/instance=otel-agent 2>/dev/null || true
      kubectl -n otel rollout restart statefulset -l app.kubernetes.io/instance=otel-gateway 2>/dev/null || true
      echo "  otel: agent + gateway"
    fi
    if kubectl -n "$ns" get deployment,daemonset,statefulset -l "$APP_SELECTOR" \
         -o name 2>/dev/null | grep -q .; then
      kubectl -n "$ns" rollout restart deployment,daemonset,statefulset -l "$APP_SELECTOR" >/dev/null
      echo "  $ns: workloads labelled $APP_SELECTOR"
    fi
  done
}

patch_all() {
  local json="$1" ns
  for ns in $(existing_namespaces); do
    kubectl -n "$ns" get configmap "$CM" >/dev/null 2>&1 \
      || die "$CM not found in namespace $ns -- run '$0 install' first"
    kubectl -n "$ns" patch configmap "$CM" --type merge -p "$json" >/dev/null
    echo "  patched $ns/$CM"
  done
}

cmd_install() {
  require_cluster
  echo "Applying ConfigMap, RBAC and the capture-expiry CronJob..."
  kubectl apply -f "$MANIFEST"
  # The manifest defines the otel copy; replicate it into the app namespaces.
  local ns
  for ns in $(existing_namespaces); do
    [ "$ns" = "otel" ] && continue
    kubectl -n otel get configmap "$CM" -o yaml \
      | sed "s/^  namespace: otel$/  namespace: $ns/" \
      | kubectl apply -f - >/dev/null
    echo "  replicated $CM into $ns"
  done
  echo
  echo "Bind the capture role to whoever is allowed to enable content capture:"
  echo "  kubectl create clusterrolebinding obs-capture-admin \\"
  echo "    --clusterrole=observability-capture-admin --user=<subject>"
}

cmd_status() {
  require_cluster
  local ns
  for ns in $(existing_namespaces); do
    kubectl -n "$ns" get configmap "$CM" >/dev/null 2>&1 || { echo "$ns: not installed"; continue; }
    local level capture expires
    level=$(kubectl -n "$ns" get configmap "$CM" -o jsonpath='{.data.OBS_LEVEL}')
    capture=$(kubectl -n "$ns" get configmap "$CM" -o jsonpath='{.data.OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT}')
    expires=$(kubectl -n "$ns" get configmap "$CM" -o jsonpath='{.data.OBS_CAPTURE_EXPIRES_AT}')
    printf '%-10s level=%-7s content-capture=%-6s%s\n' \
      "$ns" "$level" "$capture" "$([ -n "$expires" ] && echo " expires=$expires")"
  done
}

cmd_level() {
  local level="${1:-}"
  require_cluster
  case "$level" in
    normal)
      patch_all '{"data":{"OBS_LEVEL":"normal","OTEL_LOG_LEVEL":"info","OBS_COLLECTOR_LOG_LEVEL":"info","OBS_TAIL_BASELINE_PERCENTAGE":"10"}}'
      ;;
    debug)
      # Keeps every trace rather than 10%, and turns up log verbosity. Note
      # this does NOT touch content capture -- that is a separate, audited
      # decision with its own TTL.
      patch_all '{"data":{"OBS_LEVEL":"debug","OTEL_LOG_LEVEL":"debug","OBS_COLLECTOR_LOG_LEVEL":"debug","OBS_TAIL_BASELINE_PERCENTAGE":"100"}}'
      ;;
    *) die "usage: $0 level normal|debug" ;;
  esac
  restart_readers
  echo "Level is now '$level'."
}

cmd_capture() {
  local action="${1:-}" ttl="30m"
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --ttl) ttl="${2:-}"; shift 2 ;;
      *) die "unknown argument '$1'" ;;
    esac
  done
  require_cluster

  case "$action" in
    on)
      local secs expires who
      secs=$(ttl_to_seconds "$ttl")
      [ "$secs" -le 14400 ] || die "--ttl $ttl exceeds the 4h maximum; capture is meant to be short"
      expires=$(future_rfc3339 "$secs")
      who=$(kubectl auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null || echo unknown)
      echo "Enabling prompt/completion capture until $expires (requested by $who)."
      echo "Content is redacted on-node and routed to the 'agents-content' Tempo tenant (7d)."
      patch_all "{\"data\":{\"OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT\":\"true\",\"OBS_CAPTURE_EXPIRES_AT\":\"$expires\",\"OBS_LEVEL\":\"debug\"}}"
      restart_readers
      echo
      echo "It will switch itself off; the CronJob checks every 5 minutes."
      echo "To view captured content (deliberately NOT a Grafana datasource --"
      echo "see gitops/apps/08-kube-prometheus-stack.yaml for why):"
      echo "  kubectl -n tracing port-forward svc/tempo-query-frontend 3200:3200"
      echo "  curl -H 'X-Scope-OrgID: agents-content' localhost:3200/api/search"
      ;;
    off)
      patch_all '{"data":{"OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT":"false","OBS_CAPTURE_EXPIRES_AT":"","OBS_LEVEL":"normal"}}'
      restart_readers
      echo "Content capture disabled."
      ;;
    *) die "usage: $0 capture on [--ttl 30m] | off" ;;
  esac
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  status)  shift; cmd_status "$@" ;;
  level)   shift; cmd_level "$@" ;;
  capture) shift; cmd_capture "$@" ;;
  *)
    cat <<EOF
usage: $0 <command>

  install                      apply the ConfigMap, RBAC and expiry CronJob
  status                       show current level and capture state
  level normal|debug           verbosity: sampling baseline + log levels
  capture on [--ttl 30m]       enable prompt/completion capture, time-boxed
  capture off                  disable it now

Namespaces: $OBS_NAMESPACES  (override with OBS_NAMESPACES="otel default myapp")
EOF
    exit 1
    ;;
esac
