#!/usr/bin/env bash
# Builds the whole lab from nothing. Safe to run again at any time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$HOME/source/lab"
STATE_DIR="$HOME/source/.lab/state"
GH_OWNER="mjbrian"
CLUSTERS=(mgmt dev prod)
OPTIONAL_PROFILES=(observability delivery portal)
OS="$(uname -s)"
ARCH="$(uname -m)"

set -a
source "$SCRIPT_DIR/versions.env"
set +a

log() { printf '\n==> %s\n' "$*"; }

secret_get() {
  if [[ "$OS" == "Darwin" ]]; then
    security find-generic-password -s "lab-$1" -a "$USER" -w 2>/dev/null || true
  else
    secret-tool lookup service lab key "$1" 2>/dev/null || true
  fi
}

secret_set() {
  if [[ "$OS" == "Darwin" ]]; then
    security add-generic-password -U -s "lab-$1" -a "$USER" -w "$2"
  else
    printf '%s' "$2" | secret-tool store --label "lab $1" service lab key "$1"
  fi
}

ACTION="build"
PROFILE=""
case "${1:-}" in
  --destroy) ACTION="destroy" ;;
  --lock) ACTION="lock" ;;
  --profile) PROFILE="${2:?Name a profile, for example observability}" ;;
  "") ;;
  *) echo "Unknown option: $1" >&2; exit 1 ;;
esac

log "1. Installing mise and every tool"
case "$OS-$ARCH" in
  Darwin-arm64) PLATFORM="macos-arm64"; MISE_SHA256="$MISE_SHA256_MACOS_ARM64" ;;
  Linux-x86_64) PLATFORM="linux-x64"; MISE_SHA256="$MISE_SHA256_LINUX_X64" ;;
  Linux-aarch64) PLATFORM="linux-arm64"; MISE_SHA256="$MISE_SHA256_LINUX_ARM64" ;;
  *) echo "Unsupported system: $OS $ARCH. On Windows, run this inside WSL2." >&2; exit 1 ;;
esac
MISE_BIN="$HOME/.local/bin/mise"
if [[ "$("$MISE_BIN" --version 2>/dev/null || true)" != *"${MISE_VERSION#v}"* ]]; then
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/mise.tar.gz" \
    "https://github.com/jdx/mise/releases/download/$MISE_VERSION/mise-$MISE_VERSION-$PLATFORM.tar.gz"
  echo "$MISE_SHA256  $tmp/mise.tar.gz" | shasum -a 256 -c -
  tar -xzf "$tmp/mise.tar.gz" -C "$tmp"
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$tmp/mise/bin/mise" "$MISE_BIN"
  rm -rf "$tmp"
fi
export PATH="$HOME/.local/bin:$PATH"
cd "$SCRIPT_DIR"
mise trust

if [[ "$ACTION" == "lock" ]]; then
  mise lock --platform macos-arm64,linux-x64,linux-arm64
  mise install
  eval "$(mise env -s bash)"
  log "Floci digest for versions.env"
  crane digest floci/floci:latest
  exit 0
fi

mise install --locked
eval "$(mise env -s bash)"

if [[ "$ACTION" == "destroy" ]]; then
  log "Removing clusters, image caches and Floci"
  for c in "${CLUSTERS[@]}"; do k3d cluster delete "$c" || true; done
  k3d registry delete k3d-docker-io k3d-ghcr-io || true
  docker-compose -f "$SCRIPT_DIR/floci/compose.yaml" down || true
  log "Done. Saved secrets and Terraform state are kept on purpose."
  exit 0
fi

log "2. Starting the container runtime"
if [[ "$OS" == "Darwin" ]]; then
  mkdir -p "$HOME/.colima/default"
  cp "$SCRIPT_DIR/colima.yaml" "$HOME/.colima/default/colima.yaml"
  colima status >/dev/null 2>&1 || colima start
else
  docker info >/dev/null 2>&1 || { echo "Docker Engine isn't running. See Before you start." >&2; exit 1; }
fi

log "3. Signing in and making the first secrets"
gh auth status >/dev/null 2>&1 || gh auth login --web --git-protocol https
export GITHUB_TOKEN="$(gh auth token)"
if [[ -z "$(secret_get ca-key)" ]]; then
  tmp="$(mktemp -d)"
  step certificate create "Lab Root CA" "$tmp/ca.crt" "$tmp/ca.key" \
    --profile root-ca --not-after 87600h --no-password --insecure
  secret_set ca-key "$(base64 < "$tmp/ca.key" | tr -d '\n')"
  secret_set ca-crt "$(base64 < "$tmp/ca.crt" | tr -d '\n')"
  if [[ "$OS" == "Darwin" ]]; then
    security add-trusted-cert -r trustRoot \
      -k "$HOME/Library/Keychains/login.keychain-db" "$tmp/ca.crt"
  else
    sudo cp "$tmp/ca.crt" /usr/local/share/ca-certificates/lab-root-ca.crt
    sudo update-ca-certificates
  fi
  rm -rf "$tmp"
fi

log "4. Repos and GitHub settings"
mkdir -p "$LAB_DIR" "$STATE_DIR"
for r in platform-infra platform-gitops platform-tools; do
  [[ -d "$LAB_DIR/$r" ]] || gh repo clone "$GH_OWNER/$r" "$LAB_DIR/$r"
  git -C "$LAB_DIR/$r" pull --ff-only
done
tf() { terraform -chdir="$1" "${@:2}"; }
tf "$LAB_DIR/platform-infra/github" init -input=false -lockfile=readonly \
  -backend-config="path=$STATE_DIR/github.tfstate"
tf "$LAB_DIR/platform-infra/github" apply -input=false -auto-approve
