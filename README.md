# AutoPro + Show Time (Looplet)

Autonomous **ledger** execution with an optional visual **Show Time** board.

After a ledger is `Approved: yes`, you type **`/autopro`** once. A background runner
drives remaining slices to completion. Default **auto** mode picks concurrency from
how big the request is:

| Open slices (pending + in-progress) | Mode | Behaviour |
|-------------------------------------|------|-----------|
| **&lt; 12** | **serial** | One writer · one **fresh** worker process per slice (clean context) |
| **≥ 12** | **ultra** | Parallel bands · worktrees · capped concurrency |

Force anytime: `-autopro serial` · `-autopro ultra` · stop with `-autopro off`.

**Version:** [`VERSION`](./VERSION) · **Skill card:** [`SKILL.md`](./SKILL.md) · **Full skill:** [`plugins/autopro/SKILL.md`](./plugins/autopro/SKILL.md) · **Changelog:** [`CHANGELOG.md`](./CHANGELOG.md) · **Trust:** [`TRUST.md`](./TRUST.md) · **Checksums:** [`SHA256SUMS.txt`](./SHA256SUMS.txt)

---

## Install

### Preferred (short)

```bash
npx @looplet/autopro
```

Pin: `npx @looplet/autopro@1.2.0` · dry-run: `npx @looplet/autopro --dry-run`

If npm 404s (package not published yet on this machine’s registry), use Git temporarily:

```bash
npx --yes github:danielsivyer4567/looplet-autopro-skill
```

### Inspect-first (clone, no npx)

```bash
git clone https://github.com/danielsivyer4567/looplet-autopro-skill.git
cd looplet-autopro-skill
pwsh -NoProfile -File install.ps1          # Windows
# bash install.sh                          # macOS / Linux
# or: node bin/install.mjs
```

### Legacy pipe (remote bootstrap — higher risk)

```powershell
irm https://raw.githubusercontent.com/danielsivyer4567/looplet-autopro-skill/master/get.ps1 | iex
```

```bash
curl -fsSL https://raw.githubusercontent.com/danielsivyer4567/looplet-autopro-skill/master/get.sh | bash
```

`get.ps1` / `get.sh` download the GitHub archive and run local `install.ps1` / `install.sh` only. Prefer **npx** or clone.

### Verify after install

```powershell
pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/test-launch-autopro.ps1"
pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/test-crossos.ps1"
# Live board + notes (needs Show Time server):
# pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/test-orch-comms.ps1"
```

### Dry-run (no arm, no risk flags, no workers)

```powershell
pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/launch-autopro.ps1" `
  -Root <repo> -RepoDir <repo> -DryRun
```

Prints resolved mode (serial/ultra), open slice count, and the dispatch target — then exits.

---

## Serial vs ultra (what actually changes)

| | **Serial** | **Ultra** |
|--|------------|-----------|
| **When** | Small epics; default for &lt;12 open slices | Large epics; auto ≥12, or force |
| **Writers** | **One** on the checked-out branch | Multiple **band** workers in **worktrees** |
| **Context** | Fresh process per slice | Fresh process per band work |
| **Git authority** | Worker commits only; Show Time never merges | Same; no auto-merge to main |
| **Risk** | Collision if two serials on same tree | Worktree isolation per band; still no force-merge |
| **Launcher** | `launch-showtime.ps1` → `autopro-runner.ps1` | `launch-ultra.ps1` → `autopro-ultra.ps1` |

Front door for both: `scripts/launch-autopro.ps1` (`-Mode auto|serial|ultra`).

---

## Safeguards (honest list)

| Safeguard | What it does |
|-----------|----------------|
| **Risk switches** | Arm requires both `-AllowDangerousSkipPermissions` and `-IAcceptUnattendedRisk` |
| **Join gate** | Board Approve / sticky OS dialog before a new fleet lands (unless OpenRegister unattended path) |
| **Independent final gate** | After model green, runs `scripts/final-check.ps1` / `npm run gate` / env cmd |
| **Kickstart** | Worker dies in first ~12s → retry once, then needs-you |
| **Needs-you / watch** | Blocked outcomes write files + toast; optional watch console |
| **Zero git in Show Time** | Board never commit/merge/push; CI/tests enforce allowlist |
| **Single writer (serial)** | Two runners on one tree will collide (loud by design) |
| **Install backup** | `install.ps1` / `install.sh` copy existing skill to `~/.claude/autopro-backups/` |
| **Stop** | `stop-autopro.ps1 -Root <repo>` or `-All` |

Not claimed: signed releases (yet), notarized binaries, or formal SLSA provenance.

---

## Rollback

```powershell
# List backups
Get-ChildItem "$HOME/.claude/autopro-backups"

# Restore a previous install
$bak = Get-ChildItem "$HOME/.claude/autopro-backups" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Remove-Item -Recurse -Force "$HOME/.claude/skills/autopro" -ErrorAction SilentlyContinue
Copy-Item -Recurse -Force $bak.FullName "$HOME/.claude/skills/autopro"
```

Or re-clone an older git tag/commit and run `install.ps1` again.

---

## Examples

```powershell
$skill = Join-Path $HOME '.claude/skills/autopro/scripts'
$repo  = 'C:\repos\my-project'

# 1) Dry-run: what mode would this ledger get?
pwsh -NoProfile -File "$skill/launch-autopro.ps1" -Root $repo -RepoDir $repo -DryRun

# 2) Arm auto (size-based) after ledger Approved: yes
pwsh -NoProfile -File "$skill/launch-autopro.ps1" -Root $repo -RepoDir $repo `
  -AllowDangerousSkipPermissions -IAcceptUnattendedRisk

# 3) Force serial even on a large ledger
pwsh -NoProfile -File "$skill/launch-autopro.ps1" -Root $repo -RepoDir $repo -Mode serial `
  -AllowDangerousSkipPermissions -IAcceptUnattendedRisk

# 4) Stop
pwsh -NoProfile -File "$skill/stop-autopro.ps1" -Root $repo
```

Offline proof scripts (no LLM):

| Script | Proves |
|--------|--------|
| `test-launch-autopro.ps1` | Front door + size heuristic |
| `test-orch-comms.ps1` | Notes / holds / steers / nudge |
| `test-join-popup.mjs` | Sticky join UI contract |
| `test-worker-ownership.mjs` | Board pid honesty |
| `test-crossos.ps1` | Process helpers on this OS |

---

## Repo layout

```
SKILL.md                  ← package-root skill card (discoverability; points here ↓)
plugins/autopro/          ← CANONICAL skill → installed to ~/.claude/skills/autopro
  SKILL.md                ← full agent instructions (source of truth)
  scripts/                ← launch-autopro, runner, theater, tests
  theater/                ← Show Time board UI
  references/             ← contracts, workflow, engines
install.ps1 / install.sh  ← local install (preferred)
get.ps1 / get.sh          ← convenience remote bootstrap (higher risk)
VERSION · CHANGELOG.md · TRUST.md · SHA256SUMS.txt
```

---

## License

See [LICENSE](./LICENSE).
