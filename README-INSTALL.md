# Install AutoPro (any OS)

AutoPro is a Claude Code skill: after a ledger is approved, `/autopro` runs a background runner that
drives it to completion, with an optional Show Time board. The scripts are cross-OS (Windows, macOS,
Linux) — process control, paths, and worker resolution all branch on the OS.

## Install (one line — nothing to clone)

**Windows** (PowerShell):
```powershell
irm https://raw.githubusercontent.com/danielsivyer4567/looplet-autopro-skill/master/get.ps1 | iex
```

**macOS / Linux**:
```bash
curl -fsSL https://raw.githubusercontent.com/danielsivyer4567/looplet-autopro-skill/master/get.sh | bash
```

That's it. The bootstrapper downloads the skill, copies it to `~/.claude/skills/autopro/` (backing
up any existing copy to `~/.claude/autopro-backups/`), and makes sure PowerShell 7 is available
(installs it user-space, no sudo, on Mac/Linux if missing).

### Prefer to clone first?
```bash
git clone https://github.com/danielsivyer4567/looplet-autopro-skill.git autopro && cd autopro
bash install.sh          # macOS / Linux
pwsh -NoProfile -File install.ps1   # Windows
```

## Requirements

1. **PowerShell 7 (`pwsh`)** — the skill's runtime. Ships on most Windows boxes; usually absent on a
   fresh macOS/Linux. `install.sh` runs `scripts/ensure-pwsh.sh`, which installs the official
   Microsoft build into `~/.local/pwsh` (no sudo). You can run that bootstrap on its own:
   ```bash
   bash scripts/ensure-pwsh.sh   # prints PWSH=<path>, installs if missing
   ```
2. **At least one worker CLI on PATH** — `claude`, `codex`, `gemini`, or `grok` (`ollama` is
   opt-in). Default `-Engine auto` picks the first one found. `autopro-doctor.ps1` tells you what's
   missing.

## Verify the install (cross-OS self-test)
```bash
pwsh -NoProfile -File ~/.claude/skills/autopro/scripts/test-crossos.ps1
```
Expected: `==== ALL PASS ====` — process helpers, worker resolution, and path handling all work on
this OS. (Proven on Windows and Linux/WSL; see `PORT-STATUS.md`.)

## Use
1. Open Claude Code in a repo.
2. Create + approve a ledger (the `ledger` skill).
3. Type `/autopro` (or `-autopro`).
4. Stop: `pwsh -NoProfile -File ~/.claude/skills/autopro/scripts/stop-autopro.ps1 -All`

## Scope note (honest limits)
- This makes AutoPro callable on **any OS from Claude Code**. It does **not** make `/autopro` work
  *inside* GPT/Codex/Gemini as a host — those tools don't read `SKILL.md`. They can be worker
  *engines* underneath (`-Engine codex|gemini|grok`), which is a different thing.
- Windows-only conveniences that degrade gracefully elsewhere: the `cmd.exe /c start` detach
  fallback (only used if the primary detach fails) and the `chrome.exe` board auto-open (best-effort).
