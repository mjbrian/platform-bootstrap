#!/usr/bin/env bash
# Creates the lab registry and cluster. Safe to run any number of times.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# if ! k3d registry list k3d-lab-registry.localhost >/dev/null 2>&1; then
#   k3d registry create lab-registry.localhost --port 5003
# fi

if ! k3d cluster list lab >/dev/null 2>&1; then
  k3d cluster create --config "$ROOT/k3d/lab.yaml"
fi

kubectl config use-context k3d-lab
kubectl --context k3d-lab wait --for=condition=Ready nodes --all --timeout=120s
