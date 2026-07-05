#!/usr/bin/env bash
# Bash wrapper for scripts/build-applicationset.py: wires up the shared
# COMPONENT_TABLE (scripts/lib-components.sh) and file paths as env vars,
# checks python3 + PyYAML are available, then builds
# gitops/rendered/applicationset.yaml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-components.sh"

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found. Install it: brew install python3"
  exit 1
fi

if ! python3 -c "import yaml" >/dev/null 2>&1; then
  echo "PyYAML not found -- installing it (python3 -m pip install pyyaml)..."
  # python3 -m pip instead of bare pip3: pip3 isn't always on PATH even
  # when python3 is (e.g. Homebrew python without linked pip3).
  python3 -m pip install --user --break-system-packages pyyaml >/dev/null 2>&1 \
    || python3 -m pip install --user pyyaml >/dev/null 2>&1 \
    || { echo "ERROR: failed to install PyYAML. Install manually: python3 -m pip install pyyaml"; exit 1; }
  python3 -c "import yaml" >/dev/null 2>&1 \
    || { echo "ERROR: PyYAML installed but still not importable (PATH/pyenv mismatch?)."; exit 1; }
fi

export ROOT_DIR
export COMPONENT_TABLE
export OUT_FILE="$ROOT_DIR/gitops/rendered/applicationset.yaml"

echo "Building platform ApplicationSet from gitops/apps/*.yaml + versions.env + components.env..."
python3 "$SCRIPT_DIR/build-applicationset.py"
