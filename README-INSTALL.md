# Install AutoPro (any OS)

AutoPro is a Claude Code skill: after a ledger is approved, `/autopro` runs a background runner that
drives it to completion, with an optional Show Time board. Scripts are cross-OS (Windows, macOS,
Linux).

**Trust first:** see [TRUST.md](./TRUST.md) and [README.md](./README.md). Version: [VERSION](./VERSION) · [CHANGELOG.md](./CHANGELOG.md).

---

## Preferred install (inspect, then install — no pipe-to-shell)

```bash
git clone https://github.com/danielsivyer4567/looplet-autopro-skill.git
cd looplet-autopro-skill
git log -1 --oneline          # note SHA
# Optional: read install.ps1, TRUST.md, plugins/autopro/scripts/launch-autopro.ps1
pwsh -NoProfile -File install.ps1 -DryRun   # plan only
pwsh -NoProfile -File install.ps1           # Windows / any OS with pwsh
# bash install.sh                           # macOS / Linux
```

Rollback: installs always leave `~/.claude/autopro-backups/autopro.bak-<timestamp>`.

---

## Convenience install (remote bootstrap — higher risk)

`get.ps1` / `get.sh` **download and execute** whatever is on the chosen ref. That is a review red flag
for a reason — use only if you already trust this repo.

**Windows** (PowerShell):
```powershell
# Floating master (least safe)
irm https://raw.githubusercontent.com/danielsivyer4567/looplet-autopro-skill/master/get.ps1 | iex

# Pinned tag or commit (better)
$env:AUTOPRO_REF = 'v1.1.1'   # or full SHA
irm https://raw.githubusercontent.com/danielsivyer4567/looplet-autopro-skill/master/get.ps1 | iex
```

**macOS / Linux**:
```bash
curl -fsSL https://raw.githubusercontent.com/danielsivyer4567/looplet-autopro-skill/master/get.sh | bash
# Pin:
AUTOPRO_REF=v1.1.1 curl -fsSL …/get.sh | bash
```

What the bootstrapper does (and only this): download the GitHub archive → run **local**
`install.ps1` / `install.sh` from that archive (copy into `~/.claude/skills/autopro`, backup first).
No second-stage binary download.

---

## Requirements

1. **PowerShell 7 (`pwsh`)** — skill runtime. On Windows usually present; on macOS/Linux
   `install.sh` runs `scripts/ensure-pwsh.sh` (user-space, no sudo).
2. **At least one worker CLI on PATH** — `claude`, `codex`, `gemini`, or `grok` (`ollama` opt-in).
   Default `-Engine auto` picks the first found. `autopro-doctor.ps1` reports gaps.

---

## Verify install

```powershell
pwsh -NoProfile -File install.ps1 -Version
pwsh -NoProfile -File ~/.claude/skills/autopro/scripts/test-crossos.ps1
pwsh -NoProfile -File ~/.claude/skills/autopro/scripts/test-launch-autopro.ps1
# Arm plan only (no workers):
pwsh -NoProfile -File ~/.claude/skills/autopro/scripts/launch-autopro.ps1 `
  -Root <repo> -RepoDir <repo> -DryRun
```

Checksums (from package root after clone):

```powershell
pwsh -NoProfile -File plugins/autopro/scripts/write-checksums.ps1
# Compare SHA256SUMS.txt — see TRUST.md
```

---

## Use

1. Open Claude Code in a repo.
2. Create + approve a ledger (`ledger` skill).
3. Type `/autopro` (or `-autopro`). Default **auto**: open slices &lt;12 → **serial**, ≥12 → **ultra**.
   Force: `-autopro serial` or `-autopro ultra`.
4. Stop: `pwsh -NoProfile -File ~/.claude/skills/autopro/scripts/stop-autopro.ps1 -All`

### Serial vs ultra (what changes)

| | Serial | Ultra |
|--|--------|-------|
| Default when | &lt;12 open slices | ≥12 open slices |
| Writers | One on current branch | Parallel bands in worktrees |
| Context | Fresh process per slice | Fresh process per band work |
| Git | Worker commits; Show Time never merges | Same |

---

## Scope note (honest limits)

- Callable from **Claude Code** (and similar hosts that load `SKILL.md`). Other CLIs can be
  **worker engines** (`-Engine codex|gemini|grok`), not hosts.
- Not claimed yet: cosign/Sigstore signed releases, SLSA provenance. Checksums + VERSION + docs ship
  in this package; formal GitHub Release artifacts are the next trust step.
