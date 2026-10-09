#!/usr/bin/env bash
# Sets up a Mac for the platform lab. Safe to run any number of times.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
log() { printf '\n==> %s\n' "$*"; }

log "Homebrew"
if ! command -v brew >/dev/null; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi
grep -q 'brew shellenv' ~/.zprofile 2>/dev/null || \
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
brew bundle --file "$ROOT/Brewfile"

log "Shell"
LINE="source \"$ROOT/shell/lab.zsh\""
grep -qxF "$LINE" ~/.zshrc 2>/dev/null || echo "$LINE" >> ~/.zshrc

log "mise tools"
mkdir -p ~/.config/mise
ln -sf "$ROOT/mise/config.toml" ~/.config/mise/config.toml
mise trust "$ROOT/mise/config.toml"
mise install
export PATH="$HOME/.local/share/mise/shims:$PATH"

log "Plugins"
mkdir -p ~/.docker/cli-plugins
ln -sfn "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" ~/.docker/cli-plugins/docker-buildx
helm plugin list | grep -q unittest || helm plugin install https://github.com/helm-unittest/helm-unittest.git --verify=false --version v1.1.1
helm plugin list | grep -q diff || helm plugin install https://github.com/databus23/helm-diff.git --verify=false --version v3.15.15
kubectl krew install cnpg 2>/dev/null || true

if [ "${CI:-false}" = "true" ]; then
  log "CI mode. Skipping the VM, repos, signing, and AWS steps."
  exit 0
fi

log "Colima VM"
mkdir -p ~/.colima/default
[ -f ~/.colima/default/colima.yaml ] || cp "$ROOT/colima/default.yaml" ~/.colima/default/colima.yaml
colima status >/dev/null 2>&1 || colima start

log "Local cluster"
"$ROOT/scripts/cluster.sh"

log "Repos, signing, and AWS profiles"
gh auth status >/dev/null 2>&1 || gh auth login --git-protocol ssh --web
"$ROOT/scripts/clone-repos.sh"
"$ROOT/scripts/git-signing.sh"
[ -f "$ROOT/shell/lab.local.zsh" ] && source "$ROOT/shell/lab.local.zsh"
"$ROOT/scripts/aws-config.sh"

if ! k3d cluster list lab >/dev/null 2>&1; then
  k3d cluster create --config k3d/lab.yaml
fi

log "Done. Open a new terminal, run 'task aws:login', then 'task doctor'."
