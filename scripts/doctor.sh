#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
check() {
  if eval "$2" >/dev/null 2>&1; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi
}

echo "== Brewfile"
while read -r pkg; do
  check "$pkg" "brew list --versions '$pkg' || brew list --cask '$pkg'"
done < <(brew bundle list --file Brewfile --formula --cask)

echo "== mise tools"
while read -r tool _; do
  check "$tool" "mise which '$tool'"
done < <(mise ls --current --no-header)

echo "== Everything else"
check "Docker"        "docker info"
check "Helm plugins"  "helm plugin list | grep -q unittest && helm plugin list | grep -q diff"
check "Git signing"   "test \"\$(git config --global commit.gpgsign)\" = true"
check "GitHub login"  "gh auth status"
check "AWS read only" "aws sts get-caller-identity --profile lab"
check "AWS admin"     "aws sts get-caller-identity --profile lab-admin"
exit $fail
