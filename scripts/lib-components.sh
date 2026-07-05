#!/usr/bin/env bash
# Shared component registry, sourced by scripts/build-applicationset.sh and
# scripts/04-apply-apps.sh so they always agree on which Argo CD Application
# maps to which components.env flag and which sync wave.
#
# Columns: APP_NAME|ENABLED_VAR|FILE|WAVE
COMPONENT_TABLE='
cert-manager|CERT_MANAGER_ENABLED|01-cert-manager.yaml|1
metallb|METALLB_ENABLED|02-metallb.yaml|1
external-secrets|EXTERNAL_SECRETS_ENABLED|03-external-secrets.yaml|1
envoy-gateway|ENVOY_GATEWAY_ENABLED|06-envoy-gateway.yaml|2
kube-prometheus-stack|KUBE_PROMETHEUS_STACK_ENABLED|08-kube-prometheus-stack.yaml|2
tempo|TEMPO_ENABLED|04-tempo.yaml|3
alloy|ALLOY_ENABLED|05-alloy.yaml|4
loki-stack|LOKI_STACK_ENABLED|11-loki-stack.yaml|3
minio|MINIO_ENABLED|12-minio.yaml|3
velero|VELERO_ENABLED|13-velero.yaml|4
kagent-crds|KAGENT_ENABLED|14-kagent-crds.yaml|1
kagent|KAGENT_ENABLED|15-kagent.yaml|2
'

# Kubeflow and OLM are NOT in COMPONENT_TABLE above: it installs via a git+kustomize
# bundle (kubeflow/manifests), not a Helm chart, so it doesn't fit the
# uniform Helm template scripts/build-applicationset.py generates from this
# table. It lives as its own standalone Application manifest in
# gitops/special/16-kubeflow.yaml, applied/pruned directly by
# scripts/04-apply-apps.sh based on KUBEFLOW_ENABLED -- see that script and
# gitops/special/16-kubeflow.yaml for details.

# Usage: is_component_enabled "$var_name"
# Defaults to enabled if the flag is missing from components.env entirely.
is_component_enabled() {
  local var="$1"
  local val="${!var:-true}"
  [ "$val" = "true" ]
}
