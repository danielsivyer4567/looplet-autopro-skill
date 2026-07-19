# Trust posture — AutoPro skill

This document answers review questions: **what runs, with what privileges, how to
install without `irm | iex`, how to verify, how to roll back.**

## Threat model (honest)

| Trust surface | Risk | Mitigation |
|---------------|------|------------|
| `get.ps1` / `get.sh` | **Remote code execution** of whatever is on `master` | Prefer **clone + `install.ps1`**. Pin a commit. Inspect before install. |
| Worker engines | Unattended tool use on your repo | Explicit dual risk switches; join gate; stop script |
| Show Time board | Localhost only; no CORS | Token on `/api/*` except health; loopback board |
| Install | Overwrites `~/.claude/skills/autopro` | Timestamped backup under `~/.claude/autopro-backups/` |

We ship in-repo:

- `VERSION` + `CHANGELOG.md`  
- `SHA256SUMS.txt` (regenerate with `plugins/autopro/scripts/write-checksums.ps1`)  
- `-DryRun` on install + launch  
- Pin via `AUTOPRO_REF` on get.ps1/get.sh  

We do **not** currently ship:

- Cosign / Sigstore signed releases  
- Notarized installers  
- SLSA provenance / GitHub Attestations  

Those last items raise a public skill into a solid “8/10 trust” band; with docs + dry-run + checksums + preferred clone path, this is a **usable public automation package with explicit residual risk** — not an internal-only helper.

## Preferred install

```bash
npx @looplet/autopro
# pin: npx @looplet/autopro@1.2.0
# dry: npx @looplet/autopro --dry-run
```

`npx` fetches a **versioned package** from the npm registry (or GitHub if you use the git form). No `irm | iex`.

If `@looplet/autopro` is 404 on npm, until publish:

```bash
npx --yes github:danielsivyer4567/looplet-autopro-skill
```

### Inspect-first (clone)

```bash
git clone https://github.com/danielsivyer4567/looplet-autopro-skill.git
cd looplet-autopro-skill
git log -1 --oneline          # note SHA
# Read: install.ps1, bin/install.mjs, plugins/autopro/SKILL.md
pwsh -NoProfile -File install.ps1
# or: node bin/install.mjs
```

## Convenience install (pipe) — what it actually does

1. Downloads `https://github.com/…/archive/refs/heads/master.zip` (or tar.gz)  
2. Extracts  
3. Runs **`install.ps1` / `install.sh` from the archive** (file copy + backup only)

No second-stage download of arbitrary binaries. Still: **you are executing code from GitHub `master` without a pin.**

### Safer one-liner variant (pin a commit)

```powershell
# After you pick a SHA from the repo (example):
$sha = '01933ba438e421e5f117e42a98f6be315d908d0f'
$zip = "https://github.com/danielsivyer4567/looplet-autopro-skill/archive/$sha.zip"
# Download, expand, run install.ps1 from the tree — same as get.ps1 but pinned
```

Or: `git clone` + `git checkout <sha>` + `install.ps1`.

## Checksums

Generate for the skill tree you are about to install:

```powershell
pwsh -NoProfile -File plugins/autopro/scripts/write-checksums.ps1
# Writes SHA256SUMS.txt at package root (or -OutFile)
```

Verify after download (PowerShell):

```powershell
Get-FileHash -Algorithm SHA256 path\to\file
# Compare to SHA256SUMS.txt lines
```

Commit `SHA256SUMS.txt` on release tags when you publish formal releases.

## Dry-run (no arm)

```powershell
pwsh -NoProfile -File ~/.claude/skills/autopro/scripts/launch-autopro.ps1 `
  -Root <repo> -RepoDir <repo> -DryRun
```

Does **not** require risk switches. Does **not** spawn workers or open the board.

## Proof scripts (no LLM spend)

| Script | Claim |
|--------|--------|
| `test-launch-autopro.ps1` | Auto size → serial/ultra dispatch |
| `test-orch-comms.ps1` | Notes / hold / steer / nudge APIs |
| `test-join-popup.mjs` | Sticky join UI contract |
| `test-worker-ownership.mjs` | Board ownership honesty |
| `test-crossos.ps1` | Process helpers on this OS |
| `test-showtime.ps1` | Board server + zero-git allowlist |

## Rollback

See [README.md § Rollback](./README.md#rollback). Install always leaves a backup under:

`~/.claude/autopro-backups/autopro.bak-<timestamp>`

## Versioning

- `VERSION` file at package root  
- `plugins/autopro/.claude-plugin/plugin.json` → `version`  
- `CHANGELOG.md` — human log of what shipped  

## Contact / source of truth

- Source: https://github.com/danielsivyer4567/looplet-autopro-skill  
- Skill runtime path after install: `~/.claude/skills/autopro`  
