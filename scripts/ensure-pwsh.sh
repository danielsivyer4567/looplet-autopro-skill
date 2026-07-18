#!/usr/bin/env bash
# ensure-pwsh.sh — make PowerShell 7 (pwsh) available for the AutoPro skill, cross-OS, NO sudo.
#
# AutoPro's scripts are all pwsh. pwsh usually ships on Windows but is typically ABSENT on a fresh
# macOS/Linux, where the first `pwsh` call fails with "command not found". This script:
#   1) prints the pwsh path if one is already usable (PATH or a prior user-space install);
#   2) otherwise downloads the OFFICIAL Microsoft PowerShell tarball for this OS/arch into
#      ~/.local/pwsh (user space, no root), and links ~/.local/bin/pwsh.
# It writes the resolved path to stdout as `PWSH=<path>` and exits 0 on success.
set -euo pipefail

USER_PWSH_DIR="$HOME/.local/pwsh"
USER_BIN="$HOME/.local/bin"

emit() { echo "PWSH=$1"; }

# 1) already on PATH?
if command -v pwsh >/dev/null 2>&1; then emit "$(command -v pwsh)"; exit 0; fi
# 2) prior user-space install?
if [ -x "$USER_PWSH_DIR/pwsh" ]; then emit "$USER_PWSH_DIR/pwsh"; exit 0; fi

# 3) install into user space. Resolve the Microsoft runtime id (RID) for this box.
os="$(uname -s)"; arch="$(uname -m)"
case "$os" in
  Linux)  osrid="linux" ;;
  Darwin) osrid="osx" ;;
  *) echo "ensure-pwsh: unsupported OS '$os' — install PowerShell 7 manually: https://aka.ms/powershell" >&2; exit 2 ;;
esac
case "$arch" in
  x86_64|amd64)   a="x64" ;;
  aarch64|arm64)  a="arm64" ;;
  *) echo "ensure-pwsh: unsupported arch '$arch' — install PowerShell 7 manually: https://aka.ms/powershell" >&2; exit 2 ;;
esac
# Alpine / musl libc uses a different build (glibc build won't run there).
if [ "$osrid" = "linux" ] && ldd --version 2>&1 | grep -qi musl; then rid="linux-musl-${a}"; else rid="${osrid}-${a}"; fi

# Pick a downloader.
if command -v curl >/dev/null 2>&1; then DL() { curl -fsSL "$1"; } ; DLO() { curl -fsSL -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then DL() { wget -qO- "$1"; } ; DLO() { wget -qO "$2" "$1"; }
else echo "ensure-pwsh: need curl or wget to download PowerShell" >&2; exit 3; fi

echo "ensure-pwsh: pwsh not found — installing PowerShell 7 ($rid) into $USER_PWSH_DIR (no sudo)…" >&2
api="https://api.github.com/repos/PowerShell/PowerShell/releases/latest"
url="$(DL "$api" | grep -o "https://[^\"]*-${rid}.tar.gz" | grep -v fxdependent | head -1 || true)"
if [ -z "$url" ]; then
  echo "ensure-pwsh: could not resolve a PowerShell asset for '$rid'. Install manually: https://aka.ms/powershell" >&2
  exit 4
fi
echo "ensure-pwsh: asset $url" >&2
mkdir -p "$USER_PWSH_DIR"
tmp="$(mktemp)"; DLO "$url" "$tmp"
tar -xzf "$tmp" -C "$USER_PWSH_DIR"; rm -f "$tmp"
chmod +x "$USER_PWSH_DIR/pwsh"
# Convenience symlink so `pwsh` is on PATH when ~/.local/bin is (common default).
mkdir -p "$USER_BIN"; ln -sf "$USER_PWSH_DIR/pwsh" "$USER_BIN/pwsh"

if ! "$USER_PWSH_DIR/pwsh" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' >/dev/null 2>&1; then
  echo "ensure-pwsh: installed pwsh failed to run (a native dep like libicu/libssl may be missing)." >&2
  echo "  Linux: install libicu (e.g. 'apt-get install -y libicu-dev' / 'apk add icu-libs'), then re-run." >&2
  exit 5
fi
case ":$PATH:" in *":$USER_BIN:"*) : ;; *) echo "ensure-pwsh: add ~/.local/bin to PATH to call 'pwsh' directly (or use the printed path)." >&2 ;; esac
emit "$USER_PWSH_DIR/pwsh"
