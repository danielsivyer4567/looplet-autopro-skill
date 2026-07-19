#!/usr/bin/env bash
# install.sh — install the AutoPro skill into ~/.claude/skills/autopro on macOS/Linux (no sudo).
# Preferred: git clone … then bash install.sh  (see TRUST.md — avoid pipe-to-shell when reviewing).
# Usage:
#   bash install.sh
#   bash install.sh --dry-run
#   bash install.sh --version
# Idempotent: backs up any existing install to ~/.claude/autopro-backups/ first.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
SKILLSRC="$SRC/plugins/autopro"          # the skill lives inside the plugin dir
DEST="$HOME/.claude/skills/autopro"
STAMP="$(date +%Y%m%d-%H%M%S)"
PKG_VERSION="unknown"
[ -f "$SRC/VERSION" ] && PKG_VERSION="$(tr -d ' \r\n' < "$SRC/VERSION")"

DRY_RUN=0
SHOW_VERSION=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-DryRun) DRY_RUN=1 ;;
    --version|-Version) SHOW_VERSION=1 ;;
    -h|--help)
      echo "Usage: bash install.sh [--dry-run] [--version]"
      exit 0
      ;;
  esac
done

if [ "$SHOW_VERSION" = 1 ]; then
  echo "AUTOPRO_VERSION=$PKG_VERSION"
  echo "PACKAGE_ROOT=$SRC"
  exit 0
fi

if [ ! -f "$SKILLSRC/SKILL.md" ]; then
  echo "install.sh: run me from the AutoPro package dir (plugins/autopro/SKILL.md not found)." >&2
  exit 1
fi

echo "AUTOPRO_VERSION=$PKG_VERSION"
echo "INSTALL_SRC=$SKILLSRC"
echo "INSTALL_DEST=$DEST"

if [ "$DRY_RUN" = 1 ]; then
  echo "DRY_RUN=1"
  if [ -e "$DEST" ]; then
    echo "DRY_RUN_DEST_EXISTS=1"
    echo "DRY_RUN_BACKUP_WOULD= ~/.claude/autopro-backups/autopro.bak-$STAMP"
  else
    echo "DRY_RUN_DEST_EXISTS=0"
  fi
  echo "DRY_RUN_ACTION=would copy plugins/autopro → ~/.claude/skills/autopro"
  echo "DRY_RUN_NO_NETWORK=1"
  exit 0
fi

if [ -e "$DEST" ]; then
  BAK="$HOME/.claude/autopro-backups/autopro.bak-$STAMP"   # NOTE: outside skills/ so it isn't a phantom skill
  mkdir -p "$(dirname "$BAK")"
  cp -a "$DEST" "$BAK"
  echo "backed up existing skill -> $BAK"
  rm -rf "$DEST"
fi

mkdir -p "$DEST"
# Copy SKILL.md, rewriting the plugin-root placeholder to the actual install dir (non-plugin install).
sed "s|\${CLAUDE_PLUGIN_ROOT}|$DEST|g" "$SKILLSRC/SKILL.md" > "$DEST/SKILL.md"
for d in scripts references theater; do
  [ -e "$SKILLSRC/$d" ] && cp -a "$SKILLSRC/$d" "$DEST"/
done
for f in VERSION CHANGELOG.md TRUST.md SHA256SUMS.txt; do
  [ -f "$SRC/$f" ] && cp -a "$SRC/$f" "$DEST/"
done
chmod +x "$DEST"/scripts/*.sh 2>/dev/null || true
echo "AutoPro skill installed -> $DEST (v$PKG_VERSION)"

# Bootstrap PowerShell 7 (the skill's runtime). No sudo; user-space.
echo "--- ensuring pwsh ---"
if bash "$DEST/scripts/ensure-pwsh.sh"; then
  echo "pwsh OK"
else
  echo "NOTE: pwsh not ready — see messages above; the skill needs PowerShell 7 to run." >&2
fi

# Tiered colors for the speed menu (respect NO_COLOR / non-TTY)
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G='\033[32m'; B='\033[94m'; Y='\033[33m'; K='\033[90m'; Z='\033[0m'; BD='\033[1m'
else
  G=''; B=''; Y=''; K=''; Z=''; BD=''
fi

printf '\n%bDone. Next:%b\n' "$BD" "$Z"
printf '  1) Open Claude Code in a repo\n'
printf '  2) Create + approve a ledger\n'
printf '  3) Type  %b/autopro%b          (auto: small→serial, large→ultra)\n' "$G" "$Z"
printf '  4) Speed (pick one):\n'
printf '       %b/autopro%b            safe default (auto)\n' "$G" "$Z"
printf '       %b%b/autopro ultra%b      FASTEST — parallel bands\n' "$B" "$BD" "$Z"
printf '       %b/autopro serial%b     one writer, slower, simpler\n' "$K" "$Z"
printf '       %b/autopro off%b        stop\n' "$Y" "$Z"
printf '%bDry-run arm:\n' "$K"
printf '  pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/launch-autopro.ps1" -Root <repo> -RepoDir <repo> -DryRun\n'
printf 'Stop anytime:  pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/stop-autopro.ps1" -All\n'
printf 'Trust / rollback: see TRUST.md (package repo) or VERSION next to the skill.%b\n' "$Z"
