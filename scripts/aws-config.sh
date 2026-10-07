#!/usr/bin/env bash
set -euo pipefail
: "${LAB_ACCOUNT_ID:?Copy shell/lab.local.zsh.example to shell/lab.local.zsh and set it}"
mkdir -p ~/.aws && touch ~/.aws/config
if ! grep -q '^\[profile lab-admin\]' ~/.aws/config; then
  cat >> ~/.aws/config <<EOF

[profile lab-admin]
role_arn = arn:aws:iam::${LAB_ACCOUNT_ID}:role/LabAdmin
source_profile = lab
region = us-west-2
duration_seconds = 3600
EOF
fi
