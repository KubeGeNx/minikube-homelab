#!/usr/bin/env bash
# Bash wrapper for scripts/build-applicationset.py: wires up the shared
# typed catalogue and environment plan, checks python3 + PyYAML, then builds
# checked-in generated output for the selected environment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

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
# One rendered ApplicationSet per environment. ENV selects which overlay in
# environments/<env>/ is applied on top of the repo-root base files.
export ENV="${ENV:-dev}"
if [ "${1:-}" = "--check" ]; then
  TMP_OUTPUT="$(mktemp -d)"
  trap 'rm -rf "$TMP_OUTPUT"' EXIT
  export OUT_FILE="$TMP_OUTPUT/applicationset.yaml"
  python3 "$SCRIPT_DIR/build-applicationset.py"
  for artifact in applicationset.yaml platform-plan.json otel-agent-config.yaml otel-gateway-config.yaml; do
    current="$ROOT_DIR/gitops/rendered/$ENV/$artifact"
    generated="$TMP_OUTPUT/$artifact"
    if [ -f "$generated" ] && { [ ! -f "$current" ] || ! cmp -s "$generated" "$current"; }; then
      echo "ERROR: checked-in $artifact is stale for ENV=$ENV. Run: ENV=$ENV bash scripts/build-applicationset.sh" >&2
      exit 1
    fi
    if [ ! -f "$generated" ] && [ -f "$current" ]; then
      echo "ERROR: stale generated artifact $current. Run: ENV=$ENV bash scripts/build-applicationset.sh" >&2
      exit 1
    fi
  done
  echo "Checked generated plan, collector configs, and ApplicationSet for ENV=$ENV."
  exit 0
fi

export OUT_FILE="$ROOT_DIR/gitops/rendered/$ENV/applicationset.yaml"

echo "Building platform ApplicationSet (ENV=$ENV) from gitops/apps/*.yaml + base env files + environments/$ENV/..."
python3 "$SCRIPT_DIR/build-applicationset.py"
