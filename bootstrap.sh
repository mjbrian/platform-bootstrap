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

TF_DIRS=(github foundation)
TF_PLATFORMS=(-platform=darwin_arm64 -platform=linux_amd64 -platform=linux_arm64)

tf() { terraform -chdir="$1" "${@:2}"; }

sync_repos() {
  gh auth status >/dev/null 2>&1 || gh auth login --web --git-protocol https
  mkdir -p "$LAB_DIR"
  for r in platform-infra platform-gitops platform-tools; do
    [[ -d "$LAB_DIR/$r" ]] || gh repo clone "$GH_OWNER/$r" "$LAB_DIR/$r"
    git -C "$LAB_DIR/$r" pull --ff-only
  done
}

open_lock_pr() {
  local dir="$1" branch
  shift
  git -C "$dir" add "$@"
  git -C "$dir" diff --cached --quiet && return 0
  branch="chore/lock-$(date +%Y%m%d%H%M)"
  git -C "$dir" switch -c "$branch"
  git -C "$dir" commit -m "Refresh lock files"
  git -C "$dir" push -u origin HEAD
  (cd "$dir" && gh pr create --fill)
  git -C "$dir" switch -
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
  digest="$(crane digest floci/floci:latest)"
  awk -v v="FLOCI_IMAGE=\"floci/floci@$digest\"" '/^FLOCI_IMAGE=/{$0=v} {print}' \
    versions.env > versions.env.tmp && mv versions.env.tmp versions.env
  sync_repos
  for d in "${TF_DIRS[@]}"; do
    [[ -f "$LAB_DIR/platform-infra/$d/main.tf" ]] || continue
    tf "$LAB_DIR/platform-infra/$d" providers lock "${TF_PLATFORMS[@]}"
  done
  open_lock_pr "$SCRIPT_DIR" mise.lock versions.env
  open_lock_pr "$LAB_DIR/platform-infra" github/.terraform.lock.hcl foundation/.terraform.lock.hcl
  log "Lock files refreshed. Merge the pull requests, then run ./bootstrap.sh"
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
mkdir -p "$STATE_DIR"
sync_repos
tf "$LAB_DIR/platform-infra/github" init -input=false -lockfile=readonly \
  -backend-config="path=$STATE_DIR/github.tfstate"
tf "$LAB_DIR/platform-infra/github" apply -input=false -auto-approve

log "5. Floci and the pretend AWS foundation"
docker network inspect lab >/dev/null 2>&1 || docker network create lab
docker-compose -f "$SCRIPT_DIR/floci/compose.yaml" up -d
export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=us-west-2
deadline=$((SECONDS + 60))
until aws --endpoint-url http://localhost:4566 sts get-caller-identity >/dev/null 2>&1; do
  (( SECONDS < deadline )) || { echo "Floci did not start" >&2; exit 1; }
  sleep 1
done
tf "$LAB_DIR/platform-infra/foundation" init -input=false -lockfile=readonly \
  -backend-config="path=$STATE_DIR/foundation-local.tfstate"
tf "$LAB_DIR/platform-infra/foundation" apply -input=false -auto-approve \
  -var-file=env/local.tfvars
