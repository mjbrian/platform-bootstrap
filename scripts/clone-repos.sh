#!/usr/bin/env bash
set -euo pipefail
mkdir -p ~/lab
for r in platform-bootstrap platform-infra platform-gitops sample-service platform-tools; do
  [ -d ~/lab/$r/.git ] || gh repo clone "mjbrian/$r" ~/lab/$r
done
