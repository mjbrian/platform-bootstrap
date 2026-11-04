#!/usr/bin/env bash
# Builds the lab's shared base, plus one cluster when you name it. Safe to run again at any time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$HOME/.lab/build"
STATE_DIR="$HOME/.lab/state"
GH_OWNER="mjbrian"
# OPTIONAL_PROFILES=(observability delivery portal)
TF_DIRS=(github foundation clusters cluster-addons)
TF_PLATFORMS=(-platform=darwin_arm64 -platform=linux_amd64 -platform=linux_arm64)
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

tf() { terraform -chdir="$1" "${@:2}"; }

tf_init() {
  tf "$1" init -input=false -reconfigure -lockfile=readonly -backend-config="path=$2"
}

sync_repos() {
  gh auth status >/dev/null 2>&1 || gh auth login --web --git-protocol https
  mkdir -p "$LAB_DIR"
  for r in platform-infra platform-gitops platform-tools; do
    [[ -d "$LAB_DIR/$r" ]] || gh repo clone "$GH_OWNER/$r" "$LAB_DIR/$r"
    git -C "$LAB_DIR/$r" fetch --quiet origin main
    git -C "$LAB_DIR/$r" reset --quiet --hard origin/main
  done
}

open_lock_pr() {
  local dir="$1" branch f files=()
  shift
  for f in "$@"; do
    if [[ -e "$dir/$f" ]]; then files+=("$f"); fi
  done
  (( ${#files[@]} )) || return 0
  git -C "$dir" add -- "${files[@]}"
  git -C "$dir" diff --cached --quiet -- "${files[@]}" && return 0
  branch="chore/lock-$(date +%Y%m%d%H%M)"
  git -C "$dir" switch -c "$branch"
  git -C "$dir" commit -m "Refresh lock files" -- "${files[@]}"
  git -C "$dir" push -u origin HEAD
  (cd "$dir" && gh pr create --fill)
  git -C "$dir" switch -
}

helper="$(jq -r '.credsStore // empty' "$HOME/.docker/config.json" 2>/dev/null || true)"
if [[ -n "$helper" ]] && ! command -v "docker-credential-$helper" >/dev/null; then
  echo "$HOME/.docker/config.json names credential helper '$helper', which isn't installed. See P0.7." >&2
  exit 1
fi

ACTION="build"
CLUSTER=""
PROFILE=""
while (( $# )); do
  case "$1" in
    --destroy) ACTION="destroy" ;;
    --lock) ACTION="lock" ;;
    --env) ACTION="env" ;;
    --profile) PROFILE="${2:?Name a profile, for example observability}"; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) CLUSTER="$1" ;;
  esac
  shift
done
if [[ -n "$PROFILE" && -z "$CLUSTER" ]]; then
  echo "Name the cluster too, for example ./bootstrap.sh prod --profile observability" >&2
  exit 1
fi

if [[ "$ACTION" == "env" ]]; then
  FLOCI_KEY_ID=""
  FLOCI_KEY_SECRET=""
  FLOCI_KEY_ID="$(secret_get floci-key-id)"
  FLOCI_KEY_SECRET="$(secret_get floci-key-secret)"
  printf 'export AWS_ENDPOINT_URL=http://localhost:4566 AWS_REGION=us-west-2\n'
  printf 'export AWS_ACCESS_KEY_ID=%q AWS_SECRET_ACCESS_KEY=%q\n' \
    "$FLOCI_KEY_ID" "$FLOCI_KEY_SECRET"
  exit 0
fi


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
  log "Pinning Floci by its digest"
  digest="$(crane digest floci/floci:latest)"
  awk -v line="FLOCI_IMAGE=\"floci/floci@$digest\"" \
    '/^FLOCI_IMAGE=/ { $0 = line } { print }' versions.env > versions.env.tmp
  mv versions.env.tmp versions.env
  digest="$(crane digest registry:3)"
  awk -v line="REGISTRY_IMAGE=\"registry@$digest\"" \
    '/^REGISTRY_IMAGE=/ { $0 = line } { print }' versions.env > versions.env.tmp
  mv versions.env.tmp versions.env
  log "Pinning Terraform providers"
  sync_repos
  for d in "${TF_DIRS[@]}"; do
    [[ -f "$LAB_DIR/platform-infra/$d/main.tf" ]] || continue
    # providers lock reads module sources too, so install the modules first.
    tf "$LAB_DIR/platform-infra/$d" get
    tf "$LAB_DIR/platform-infra/$d" providers lock "${TF_PLATFORMS[@]}"
  done
  log "Opening pull requests for anything that changed"
  open_lock_pr "$SCRIPT_DIR" mise.toml mise.lock versions.env
  open_lock_pr "$LAB_DIR/platform-infra" github/.terraform.lock.hcl foundation/.terraform.lock.hcl \
    clusters/.terraform.lock.hcl cluster-addons/.terraform.lock.hcl
  log "Merge those pull requests, then run ./bootstrap.sh"
  exit 0
fi

mise install --locked
eval "$(mise env -s bash)"

if [[ "$ACTION" == "destroy" ]]; then
  export AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_REGION=us-west-2
  targets="$CLUSTER"
  if [[ -z "$targets" ]]; then
    targets="$(find "$STATE_DIR/clusters" 2>/dev/null | sed -n 's/\.tfstate$//p')"
  fi
  if aws --endpoint-url http://localhost:4566 sts get-caller-identity >/dev/null 2>&1; then
    for c in $targets; do
      log "Removing cluster $c"
      tf_init "$LAB_DIR/platform-infra/clusters" "$STATE_DIR/clusters/$c.tfstate"
      tf "$LAB_DIR/platform-infra/clusters" destroy -input=false -auto-approve \
        -var "eks_version=$EKS_VERSION" -var-file=env/local.tfvars -var-file="env/$c.tfvars"
      rm -f "$STATE_DIR/cluster-addons/$c.tfstate"* "$STATE_DIR/profile-$c"
    done
  fi
  if [[ -z "$CLUSTER" ]]; then
    log "Stopping Floci and the image caches"
    docker-compose -f "$SCRIPT_DIR/floci/compose.yaml" down || true
  fi
  log "Done. Saved secrets and Terraform state are kept on purpose."
  exit 0
fi

log "2. Starting the container runtime"
helper="$(jq -r '.credsStore // empty' "$HOME/.docker/config.json" 2>/dev/null || true)"
if [[ -n "$helper" ]] && ! command -v "docker-credential-$helper" >/dev/null; then
  echo "$HOME/.docker/config.json names credential helper '$helper', which isn't installed. See P0.7." >&2
  exit 1
fi
if [[ "$OS" == "Darwin" ]]; then
  mkdir -p "$HOME/.colima/default"
  cp "$SCRIPT_DIR/colima.yaml" "$HOME/.colima/default/colima.yaml"
  colima status >/dev/null 2>&1 || colima start
else
  docker info >/dev/null 2>&1 || { echo "Docker Engine isn't running. See Before you start." >&2; exit 1; }
fi

log "3. Signing in and making the first secrets"
gh auth status >/dev/null 2>&1 || gh auth login --web --git-protocol https
export GITHUB_TOKEN=""
GITHUB_TOKEN="$(gh auth token)"
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

log "6. A sign in key for the pretend EKS"
key_id="$(secret_get floci-key-id)"
if [[ -z "$key_id" ]] || ! aws --endpoint-url http://localhost:4566 iam list-access-keys \
    --user-name lab-admin --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null \
    | grep -q "$key_id"; then
  aws --endpoint-url http://localhost:4566 iam get-user --user-name lab-admin >/dev/null 2>&1 \
    || aws --endpoint-url http://localhost:4566 iam create-user --user-name lab-admin >/dev/null
  key="$(aws --endpoint-url http://localhost:4566 iam create-access-key --user-name lab-admin --output json)"
  secret_set floci-key-id "$(jq -r .AccessKey.AccessKeyId <<<"$key")"
  secret_set floci-key-secret "$(jq -r .AccessKey.SecretAccessKey <<<"$key")"
fi
export AWS_ENDPOINT_URL=""
export AWS_ACCESS_KEY_ID=""
export AWS_SECRET_ACCESS_KEY=""
AWS_ENDPOINT_URL=http://localhost:4566
AWS_ACCESS_KEY_ID="$(secret_get floci-key-id)"
AWS_SECRET_ACCESS_KEY="$(secret_get floci-key-secret)"

if [[ -z "$CLUSTER" ]]; then
  log "Shared base ready. Build a cluster with ./bootstrap.sh dev or ./bootstrap.sh prod"
  exit 0
fi
c="$CLUSTER"
for d in clusters cluster-addons; do
  [[ -f "$LAB_DIR/platform-infra/$d/env/$c.tfvars" ]] \
    || { echo "No settings for $c. Add platform-infra/$d/env/$c.tfvars first." >&2; exit 1; }
done
mkdir -p "$STATE_DIR/clusters" "$STATE_DIR/cluster-addons"

log "7. Cluster $c"
tf_init "$LAB_DIR/platform-infra/clusters" "$STATE_DIR/clusters/$c.tfstate"
tf "$LAB_DIR/platform-infra/clusters" apply -input=false -auto-approve \
  -var "eks_version=$EKS_VERSION" -var-file=env/local.tfvars -var-file="env/$c.tfvars"

log "8. kubectl entry for $c"
aws eks update-kubeconfig --name "$c" --alias "$c" --user-alias "$c" >/dev/null

log "9. What $c needs before Argo CD"
if [[ -n "$PROFILE" ]]; then
  [[ "$PROFILE" == "none" ]] && PROFILE=""
  printf '%s' "$PROFILE" > "$STATE_DIR/profile-$c"
fi
tf_init "$LAB_DIR/platform-infra/cluster-addons" "$STATE_DIR/cluster-addons/$c.tfstate"
tf "$LAB_DIR/platform-infra/cluster-addons" apply -input=false -auto-approve \
  -var-file=env/local.tfvars -var-file="env/$c.tfvars" \
  -var "kube_proxy_version=$KUBE_PROXY_VERSION" \
  -var "gitops_dir=$LAB_DIR/platform-gitops" \
  -var "profile=$(cat "$STATE_DIR/profile-$c" 2>/dev/null || true)"
kubectl --context "$c" wait --for=condition=Ready nodes --all --timeout=300s

log "10. Lab certificate authority in $c"
kubectl --context "$c" create namespace cert-manager --dry-run=client -o yaml \
  | kubectl --context "$c" apply -f -
kubectl --context "$c" -n cert-manager create secret tls lab-ca \
  --cert=<(secret_get ca-crt | base64 -d) --key=<(secret_get ca-key | base64 -d) \
  --dry-run=client -o yaml | kubectl --context "$c" apply -f -

log "11. Handing $c to its own Argo CD"
kubectl --context "$c" apply -f "$LAB_DIR/platform-gitops/bootstrap/root.yaml"

log "12. Waiting until every Application in $c is Synced and Healthy"
deadline=$((SECONDS + 900))
while true; do
  not_ready=$(kubectl --context "$c" -n argocd get applications -o json \
    | jq '[.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy")] | length')
  [[ "$not_ready" == "0" ]] && break
  (( SECONDS < deadline )) || { echo "$c still not ready after 15 minutes" >&2; exit 1; }
  sleep 10
done
log "$c ready in $SECONDS seconds"
echo "Your terminal: eval \"\$(./bootstrap.sh --env)\""
echo "Argo CD password: kubectl --context $c -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "Argo CD page: kubectl --context $c -n argocd port-forward svc/argocd-server 8080:80, then open http://localhost:8080"
