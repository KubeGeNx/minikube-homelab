#!/usr/bin/env bash
# Standalone entry point: installs everything bootstrap.sh and
# update-versions.sh need (Homebrew, minikube, kubectl, helm, envsubst, jq,
# python3). Safe to run on its own, any time, before ./bootstrap.sh -- it's
# also called automatically as step 1 of ./bootstrap.sh, so running it here
# first is optional but lets you fix/re-run just this part in isolation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/scripts/00-prereqs.sh"
