#!/usr/bin/env bash
# get.sh — convenience remote bootstrap for macOS / Linux.
#
# ⚠  REMOTE CODE EXECUTION. Prefer clone + install:
#     git clone https://github.com/danielsivyer4567/looplet-autopro-skill.git
#     cd looplet-autopro-skill && bash install.sh
#
# Convenience:
#     curl -fsSL https://raw.githubusercontent.com/danielsivyer4567/looplet-autopro-skill/master/get.sh | bash
#
# Pin (safer than floating master):
#     AUTOPRO_REF=v1.1.1 curl -fsSL …/get.sh | bash
#
# Does only: download archive → run install.sh from it (backup + copy).
# See TRUST.md / README.md.
set -euo pipefail
OWNER=danielsivyer4567; REPO=looplet-autopro-skill
REF="${AUTOPRO_REF:-master}"

echo ""
echo "AutoPro get.sh — CONVENIENCE INSTALL (remote bootstrap)"
echo "This downloads and executes code from GitHub. Preferred: clone + install.sh (see TRUST.md)."
echo "REF=$REF"
echo ""

if [ "$REF" = "master" ] || [ "$REF" = "main" ]; then
  URL="https://github.com/$OWNER/$REPO/archive/refs/heads/$REF.tar.gz"
elif echo "$REF" | grep -Eq '^[0-9a-f]{7,40}$'; then
  URL="https://github.com/$OWNER/$REPO/archive/$REF.tar.gz"
else
  URL="https://github.com/$OWNER/$REPO/archive/refs/tags/$REF.tar.gz"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "AutoPro: downloading $URL …"
if command -v curl >/dev/null 2>&1; then
  if ! curl -fsSL "$URL" | tar -xz -C "$TMP"; then
    # tag miss → try heads
    URL="https://github.com/$OWNER/$REPO/archive/refs/heads/$REF.tar.gz"
    echo "retry: $URL"
    curl -fsSL "$URL" | tar -xz -C "$TMP"
  fi
elif command -v wget >/dev/null 2>&1; then
  wget -qO- "$URL" | tar -xz -C "$TMP"
else
  echo "AutoPro: need curl or wget to download" >&2
  exit 1
fi

# GitHub tarballs extract to <repo>-<ref>/ (branch, tag, or short sha forms vary)
SRC=""
for d in "$TMP"/*; do
  if [ -f "$d/install.sh" ]; then SRC="$d"; break; fi
done
[ -n "$SRC" ] && [ -f "$SRC/install.sh" ] || { echo "AutoPro: downloaded archive missing install.sh" >&2; exit 1; }
[ -f "$SRC/VERSION" ] && echo "package VERSION=$(tr -d ' \r\n' < "$SRC/VERSION")"
bash "$SRC/install.sh"
