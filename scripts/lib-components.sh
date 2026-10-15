#!/usr/bin/env bash
# Compatibility view for older shell callers. The typed YAML catalogue is the
# source of truth; this table is generated at source time for Helm-only loops.
LIB_COMPONENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_COMPONENTS_ROOT="$(dirname "$LIB_COMPONENTS_DIR")"
COMPONENT_TABLE="$(python3 - "$LIB_COMPONENTS_ROOT/config/platform-catalog.yaml" <<'PY'
import sys, yaml, os
with open(sys.argv[1]) as f:
    entries = yaml.safe_load(f)["components"]
for name, item in entries.items():
    if item["adapter"] == "helm":
        print("|".join((name, item["flag"], os.path.basename(item["manifest"]), str(item["wave"]))))
PY
)"

# Usage: is_component_enabled "$var_name". Missing flags retain the historic
# default-on behavior; environment overlays are resolved by the Python planner.
is_component_enabled() {
  local var="$1"
  local val="${!var:-true}"
  [ "$val" = "true" ]
}
