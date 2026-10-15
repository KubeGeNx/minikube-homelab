#!/usr/bin/env bash
# Renders gitops/apps/*.yaml -> gitops/rendered/*.yaml for every ENABLED
# component: substitutes the ${VAR} version placeholders using versions.env,
# and skips any component whose flag in components.env is "false".
#
# gitops/rendered/ is generated output -- never edit it by hand. Change
# versions.env for versions, components.env for on/off, never a file
# under gitops/apps/*.yaml's targetRevision directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
VERSIONS_FILE="$ROOT_DIR/versions.env"
COMPONENTS_FILE="$ROOT_DIR/components.env"
SRC_DIR="$ROOT_DIR/gitops/apps"
OUT_DIR="$ROOT_DIR/gitops/rendered"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-components.sh"

if ! command -v envsubst >/dev/null 2>&1; then
  echo "ERROR: envsubst not found. Install it (it ships with gettext):"
  echo "  brew install gettext && brew link --force gettext"
  exit 1
fi

for f in "$VERSIONS_FILE" "$COMPONENTS_FILE"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: $f not found."
    exit 1
  fi
done

# Load versions.env and components.env into the environment.
set -a
# shellcheck disable=SC1090
source "$VERSIONS_FILE"
# shellcheck disable=SC1090
source "$COMPONENTS_FILE"
set +a

# Build the explicit list of ${VAR} names envsubst should touch, so it
# never accidentally mangles an unrelated '$' in a values block.
VAR_NAMES="$(grep -oE '^[A-Z_]+=' "$VERSIONS_FILE" | sed 's/=$//' | sed 's/^/$/' | tr '\n' ' ')"

mkdir -p "$OUT_DIR"
# Only clear files THIS script renders (mirrors of gitops/apps/*.yaml).
# gitops/rendered/ is shared: applicationset.yaml (build-applicationset.sh)
# and 16-kubeflow.yaml (04-apply-apps.sh) live there too and must survive.
for f in "$SRC_DIR"/*.yaml; do
  rm -f "$OUT_DIR/$(basename "$f")"
done

echo "Rendering enabled components from gitops/apps/*.yaml using versions.env + components.env ..."
while IFS='|' read -r app enabled_var file wave; do
  [ -z "$app" ] && continue

  if ! is_component_enabled "$enabled_var"; then
    echo "  skipping $app (disabled: $enabled_var=${!enabled_var:-unset})"
    continue
  fi

  src="$SRC_DIR/$file"
  if [ ! -f "$src" ]; then
    echo "  WARNING: $src not found for enabled component '$app', skipping"
    continue
  fi

  envsubst "$VAR_NAMES" < "$src" > "$OUT_DIR/$file"
  if grep -q '\${[A-Z][A-Z0-9_]*_VERSION}' "$OUT_DIR/$file"; then
    echo "  ERROR: unresolved placeholder(s) in $file:"
    grep '\${[A-Z][A-Z0-9_]*_VERSION}' "$OUT_DIR/$file"
    exit 1
  fi
  echo "  rendered $file ($app)"
done <<< "$COMPONENT_TABLE"

echo "Done. Rendered manifests are in gitops/rendered/."
