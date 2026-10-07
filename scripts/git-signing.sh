#!/usr/bin/env bash
set -euo pipefail
KEY=~/.ssh/id_ed25519_signing
TITLE="$(hostname -s) signing"
[ -f "$KEY" ] || ssh-keygen -t ed25519 -C "$TITLE" -f "$KEY"
gh ssh-key list | grep -qF "$TITLE" || gh ssh-key add "$KEY.pub" --type signing --title "$TITLE"
git config --global gpg.format ssh
git config --global user.signingkey "$KEY.pub"
git config --global commit.gpgsign true
