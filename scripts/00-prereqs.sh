#!/usr/bin/env bash
# Installs everything this platform's scripts need: Homebrew itself (if
# missing), then minikube/kubectl/helm/envsubst (for bootstrap.sh), jq
# (for update-versions.sh), and python3 (for scripts/build-applicationset.py
# -- PyYAML is installed separately by scripts/build-applicationset.sh the
# first time it runs). curl ships with macOS by default but is checked too
# in case of a stripped-down environment.
set -euo pipefail

missing=0

install_homebrew_if_missing() {
  if command -v brew >/dev/null 2>&1; then
    return
  fi

  if [ "$(uname -s)" != "Darwin" ]; then
    echo "Homebrew not found and this isn't macOS -- install the tools below manually."
    return
  fi

  echo "Homebrew not found. Installing it (non-interactive; may prompt for your sudo password)..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Make brew available in this shell without requiring a new terminal.
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  if command -v brew >/dev/null 2>&1; then
    echo "Homebrew installed."
  else
    echo "Homebrew install finished but 'brew' isn't on PATH yet."
    echo "Open a new terminal (or follow the 'Next steps' the installer printed above) and re-run this script."
    exit 1
  fi
}

# Best-effort version string for the OK line. Tries the common flag
# spellings in an order that never hits the network (curl/kubectl/etc. all
# answer one of these locally) and falls back to plain "present".
tool_version() {
  local bin="$1" out
  out="$("$bin" --version 2>/dev/null | head -n1)"
  [ -n "$out" ] || out="$("$bin" version --client 2>/dev/null | head -n1)"
  [ -n "$out" ] || out="$("$bin" version 2>/dev/null | head -n1)"
  [ -n "$out" ] || out="present"
  echo "$out"
}

# Auto-installs the given tool via Homebrew if it's missing and brew is
# available; otherwise just reports it as missing.
check() {
  local bin="$1" formula="$2" post_install="${3:-}"

  if command -v "$bin" >/dev/null 2>&1; then
    echo "  OK: $bin ($(tool_version "$bin"))"
    return
  fi

  if command -v brew >/dev/null 2>&1; then
    echo "  MISSING: $bin  ->  installing via 'brew install $formula'..."
    if brew install "$formula"; then
      if [ -n "$post_install" ]; then
        # || warning: a failed post-install step (e.g. brew link) must not
        # silently kill the whole script under set -e.
        eval "$post_install" || echo "  WARNING: post-install step failed: $post_install"
      fi
    fi
    if command -v "$bin" >/dev/null 2>&1; then
      echo "  OK: $bin (installed)"
      return
    fi
    echo "  FAILED to install $bin automatically. Install manually: brew install $formula"
  else
    echo "  MISSING: $bin  ->  brew not found. Install Homebrew (https://brew.sh) or install $formula manually."
  fi
  missing=1
}

install_homebrew_if_missing

echo "Checking required tools..."
check minikube  minikube
check kubectl   kubectl
check helm      helm
check envsubst  gettext "brew link --force gettext"
check jq        jq
check curl      curl
check python3   python3

if [ "$missing" -eq 1 ]; then
  echo ""
  echo "Install the missing tools above, then re-run bootstrap.sh."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo ""
  echo "WARNING: 'docker info' failed. If you're using the docker driver,"
  echo "make sure Docker Desktop (or another container runtime) is running."
fi

echo "All prerequisites present."
