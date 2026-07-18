#!/usr/bin/env bash
# get.sh — AutoPro one-line web installer for macOS / Linux.
#
# Run this (nothing to clone, nothing to cd into):
#
#     curl -fsSL https://raw.githubusercontent.com/danielsivyer4567/looplet-autopro-skill/master/get.sh | bash
#
# It downloads the skill, installs it to $HOME/.claude/skills/autopro (backing up any existing
# copy), and installs PowerShell 7 into ~/.local/pwsh if you don't have it (no sudo).
set -euo pipefail
OWNER=danielsivyer4567; REPO=looplet-autopro-skill; BRANCH=master
URL="https://github.com/$OWNER/$REPO/archive/refs/heads/$BRANCH.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "AutoPro: downloading the skill…"
if command -v curl >/dev/null 2>&1; then curl -fsSL "$URL" | tar -xz -C "$TMP"
elif command -v wget >/dev/null 2>&1; then wget -qO- "$URL" | tar -xz -C "$TMP"
else echo "AutoPro: need curl or wget to download" >&2; exit 1; fi

# GitHub tarballs extract to <repo>-<branch>/
SRC="$TMP/${REPO}-${BRANCH}"
[ -f "$SRC/install.sh" ] || { echo "AutoPro: downloaded archive missing install.sh" >&2; exit 1; }
bash "$SRC/install.sh"
