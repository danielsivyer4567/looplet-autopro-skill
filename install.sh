#!/usr/bin/env bash
# install.sh — install the AutoPro skill into ~/.claude/skills/autopro on macOS/Linux (no sudo).
# Usage:  bash install.sh
# Idempotent: backs up any existing install to ~/.claude/autopro-backups/ first.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.claude/skills/autopro"
STAMP="$(date +%Y%m%d-%H%M%S)"

if [ ! -f "$SRC/SKILL.md" ]; then
  echo "install.sh: run me from the AutoPro package dir (SKILL.md not found next to me)." >&2
  exit 1
fi

if [ -e "$DEST" ]; then
  BAK="$HOME/.claude/autopro-backups/autopro.bak-$STAMP"   # NOTE: outside skills/ so it isn't a phantom skill
  mkdir -p "$(dirname "$BAK")"
  cp -a "$DEST" "$BAK"
  echo "backed up existing skill -> $BAK"
  rm -rf "$DEST"
fi

mkdir -p "$DEST"
cp -a "$SRC/SKILL.md" "$DEST"/
for d in scripts references theater; do
  [ -e "$SRC/$d" ] && cp -a "$SRC/$d" "$DEST"/
done
chmod +x "$DEST"/scripts/*.sh 2>/dev/null || true
echo "AutoPro skill installed -> $DEST"

# Bootstrap PowerShell 7 (the skill's runtime). No sudo; user-space.
echo "--- ensuring pwsh ---"
if bash "$DEST/scripts/ensure-pwsh.sh"; then
  echo "pwsh OK"
else
  echo "NOTE: pwsh not ready — see messages above; the skill needs PowerShell 7 to run." >&2
fi

cat <<'EOF'

Done. Next:
  1) Open your agent (Claude Code) in a repo.
  2) Create + approve a ledger (the `ledger` skill).
  3) Type  /autopro   (or -autopro).
Stop anytime:  pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/stop-autopro.ps1" -All
EOF
