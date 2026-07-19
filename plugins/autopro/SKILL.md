---
name: autopro
description: "One skill for autonomous ledger execution + Show Time (Looplet). Default AUTO: pick serial vs ultra from how big the ledger is (open slices). Force with `-autopro serial` or `-autopro ultra`. Serial = one writer, one FRESH worker process per slice. Ultra = parallel bands + worktrees. Same engines, board, stop. `-autopro off` stops it. Pairs with `ledger` and `work`."
trigger: /autopro
---

# autopro + Show Time (Looplet)

**One skill. Size of the request picks concurrency — unless you force it.**

| Call | Mode | What runs |
|------|------|-----------|
| `-autopro` / `/autopro` | **auto** (default) | Count open ledger slices: **&lt; 12 → serial**, **≥ 12 → ultra** (tunable) |
| `-autopro ultra` / `parallel` | **FASTEST** | Parallel bands · worktrees · capped concurrency |
| `-autopro serial` | force **serial** | One writer · one fresh worker process per slice (slower, simpler) |
| `-autopro off` | stop | `stop-autopro.ps1` |

**Chat speed cheat-sheet (say exactly this):** `/autopro` · `/autopro ultra` · `/autopro serial` · `/autopro off`

| Open slices (pending + in-progress) | Auto picks |
|-------------------------------------|------------|
| 1–11 | **serial** — simpler, safer single writer |
| 12+ | **ultra** — parallel bands (cap concurrency to ledger size) |

Tune: `-SerialMaxSlices 12` or env `AUTOPRO_SERIAL_MAX_SLICES`.

Front door:

```powershell
pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/launch-autopro.ps1" `
  -Root '<repo>' -RepoDir '<repo>' `
  -AllowDangerousSkipPermissions -IAcceptUnattendedRisk
# force: -Mode serial | -Mode ultra
# plan only (no arm): add -DryRun  (no risk switches needed)
```

Install trust: prefer `git clone` + `install.ps1` over `irm | iex`. See package `TRUST.md`, `VERSION`, `CHANGELOG.md`, `SHA256SUMS.txt`.

`work` does one slice, commits, and stops so you can `/clear` and run `work`
again. **Auto/serial** `autopro` removes both manual steps: you type `-autopro` **once**, and a
background runner drives the ledger to completion on its own.

**Multi-engine (not Claude-only):** the worker is pluggable —
`claude | codex | gemini | grok | ollama`. Default **`-Engine auto`** picks the
first installed agentic CLI. Pin with `-Engine codex` (etc). See
`references/ENGINES.md`, checklist `references/BULLETPROOF.md`. Doctor: `scripts/autopro-doctor.ps1`.

**Show Time** is the optional visual board (v2): arcade **horizontal** Pac-Man
lanes per chat, a left **monitor Pac** that watches/locks onto problems, Mission
Status modal, right ops sidebar (in-flight, sentinel, checklist, steer), bottom
per-chat notes/questions ledges, token-saver + tok/s + lines/tok·min stats.

Default board port **8770** (8766 is often Electron). Live URL is emitted **once** on the TV card / `SHOWTIME_URL` after arm (reads `server.port`).  
Credit: **Show Time - Looplet**.

## Why a background runner

Agent CLIs cannot clear their own context mid-ledger. Each slice is a brand-new
process (`claude -p`, `codex exec`, `gemini -p`, …) = genuinely clean context.
The runner loops one slice per process.

Canonical scripts live in this skill:

| Script | Role |
|--------|------|
| `scripts/launch-autopro.ps1` | **Single entry** — `-Mode serial` (default) or `-Mode ultra` |
| `scripts/launch-showtime.ps1` | Serial arm: flag + Show Time + detach runner + watch (**no git**) |
| `scripts/launch-ultra.ps1` | Parallel arm: band orchestrator + worktrees |
| `scripts/autopro-watch.ps1` | Poll chat-inbox / needs-you (minimized console; keeps human in the loop) |
| `scripts/arm-on-approve.ps1` | **Door A→B:** after board **Approve**, arm workers in that repo |
| `scripts/autopro-runner.ps1` | Serial slice loop (**no git** — the worker commits its own slice) |
| `scripts/autopro-ultra.ps1` | Parallel band loop |
| `scripts/worker-engines.ps1` | Multi-engine resolve + argv adapters (claude/codex/gemini/grok/ollama) |
| `scripts/autopro-doctor.ps1` | Preflight engines/ledger/gate (no arm) |
| `scripts/ultra-clean.ps1` | Reclaim finished/old ultra worktrees (`-RepoDir`, `-OnlyComplete`, `-OlderThanDays`, `-WhatIf`) — worktree remove + prune, never deletes branches/history |
| `scripts/showtime-final-check.ps1` | Completion gate: decode worker result → green/red verdict |

**Approve vs Arm (read first):** `references/APPROVE-ARM-CONTRACT.md` — board Approve opens arm when the ledger is `Approved: yes`; Show Time is housing only.  
**Cold handover:** `references/SHOWTIME-HANDOVER.md` (ORCH head, one worker per column, logs, kill switches).
| `scripts/theater-server.mjs` | Localhost Show Time server (port 8770+) |
| `scripts/theater-register.ps1` | ensure / register / heartbeat / complete |
| `scripts/showtime-open-board.ps1` | **Always** open board URL in browser; companion/extension hooks additive |
| `scripts/test-showtime.ps1` | Automated board tests (no LLM) |
| `scripts/test-worker-engines.ps1` | Offline multi-engine unit tests |
| `scripts/smoke-worker-engines.ps1` | Live `--version` smoke (no LLM tokens) |
| `theater/index.html` | Show Time UI |
| `theater/tips.json` | Pause-screen rotating tips |
| `references/ENGINES.md` | Engine matrix + env vars |

## Requirements (works on Windows, macOS, Linux)

The scripts are cross-OS: process control, paths (`$HOME` + forward slashes), and worker
resolution all branch on the OS. Two things must be true on the host:

1. **PowerShell 7 (`pwsh`)** — NOT Windows PowerShell 5.1. It ships on most Windows boxes but is
   usually **absent on a fresh macOS/Linux**, where the first `pwsh` call would fail with
   `command not found`. Ensure it first (no sudo, user-space):
   ```bash
   bash "$HOME/.claude/skills/autopro/scripts/ensure-pwsh.sh"    # prints the pwsh path, installs if missing
   ```
   On Windows, `pwsh` is normally already present (`winget install Microsoft.PowerShell` if not).
2. **At least one worker CLI on PATH** — `claude` / `codex` / `gemini` / `grok` (or `ollama`,
   opt-in). `autopro-doctor.ps1` preflights this and names what's missing.

Everywhere below, `$HOME` resolves to the user's home on all three OSes (pwsh sets it on Windows too).

## When you type `-autopro` (serial default)

1. **Preconditions.** Read `.claude/scratch/ledger.md`.
   - No ledger → "Run `ledger` first." Stop.
   - `Approved:` is not `yes` → "Approve the ledger first." Stop.
   - Prefer: if `autopro-on` already exists and a runner is healthy, say already
     armed (still open Show Time URL if useful).
2. **Arm + Show Time + launch** (run from the repo, on the branch you want the work on):

   ```powershell
   $skill = Join-Path $HOME '.claude/skills/autopro/scripts'   # $HOME works on Windows + macOS + Linux
   $root  = '<YOUR-REPO-ROOT>'   # scratch + flag root
   $repo  = $root                                  # ledger lives here
   # Preferred front door (auto size → serial or ultra)
   & pwsh -NoProfile -File (Join-Path $skill 'launch-autopro.ps1') `
     -Root $root -RepoDir $repo `
     -AllowDangerousSkipPermissions -IAcceptUnattendedRisk
   # Force: -Mode serial | -Mode ultra
   # Legacy direct: launch-showtime.ps1 / launch-ultra.ps1 still work
   ```

   Serial path (`launch-showtime.ps1`) when auto picks serial or you force it:
   - writes `autopro-on`
   - touches **no git** — no worktree, no branch, no commit (see the contract below)
   - starts **Show Time** server if needed (singleton)
   - **registers** this chat as a numbered lane
   - **ensures Looplet companion** on `:4321` (keep if healthy; start if down)
   - **always opens the Board in a real browser tab** at the live `http://127.0.0.1:<port>/`
     (extension/companion hooks are additive — they must not replace the browser open)
   - detaches `autopro-runner.ps1` with a stable `SessionId`

   **Required:** you MUST actually run `launch-showtime.ps1` via the shell.
   Printing the TV card alone does **not** start the server, open localhost, or arm the runner.

   Then **stop** — do not also run `work` yourself; the runner owns the loop.

3. **Report in chat as a short SHOWTIME TV** (chat only — not on the 127 board).
   Keep it minimal:

   - Wireframe TV with **SHOWTIME** + **ON AIR** on the screen
   - **Monochrome only** — never emit ANSI (`\x1b[94m` etc.); hosts strip ESC and leave `[94mLOOPLET[0m`
   - **Board URL once on the screen** as a bare `http://…` line (never `[url](url)`)
   - **Manual log** command for terminal watch
   - Do **not** wrap the TV in a fenced code block
   - No second Board line under the TV

   Template: `theater/showtime-tv-card.md` (keep it short; do not invent a second design).

   Screen lines (swap port if needed):

            LOOPLET    CHANNEL 3
                      ON AIR
                  S H O W  T I M E
               http://127.0.0.1:8770/
            autonomous ledger  ● LIVE

   Full frame: `theater/showtime-tv-card.md`. Then:

   # SHOWTIME · ON AIR

   **Manual log:**
   ```powershell
   Get-Content ".claude/scratch/autopro.log" -Wait
   ```


## Show Time runs ZERO git — read this before adding any

Show Time is a **cinema, not a landlord**. It projects what a repo's build is
doing and can send a nudge back. It never creates a branch, a worktree, or a
commit.

This is enforced, not just promised. `test-showtime.ps1` scans every `.ps1` and
`.mjs` in `scripts/`, finds **every** git invocation, and fails unless each one
uses a read-only verb (`rev-parse`, `status`, `log`, `diff`, …). It is an
allowlist, not a denylist of bad verbs — a denylist missed the house idiom
`& git -C $dir commit` (the exact form the deleted scripts used), so any verb
nobody thought of fails too. The suite also asserts the sweep still catches that
idiom, so the guard cannot silently rot.

**Why it was taken away.** Show Time used to own a full git lifecycle: arm →
scoped commit → merge → prune. Work lived in `.worktrees-showtime/sess_*` on a
`showtime/sess_*` branch, and `finish` was the **only road home**. If finish
never ran — session died, gate went red, merge conflicted, window closed — the
tree was orphaned *with the work inside it*, and nothing surfaced it. Five
orphans accumulated unnoticed; the effort in them got silently rebuilt on main.
The failure was not a bug in `finish`, it was that a projector held write
authority over a repo at all. So the authority is **deleted, not guarded**.

| Step | Behavior now |
|------|--------------|
| Arm | Runs **in the repo**, on the branch you already checked out. No worktree, no branch. |
| Each slice | The worker's own `work` skill commits its slice. The runner does not stage or commit. |
| Ledger complete | Final check runs, result is **reported**. Nothing is merged; the work is already on your branch. |

**Isolation is gone by design.** Sessions no longer get a private tree, so two
runners on one repo will share a working tree and step on each other. That is the
accepted trade: a stranded-work bug is silent and expensive, a collision is loud
and immediate. **Single writer per repo** — if you want parallel epics, give each
one its own branch and its own checkout *yourself*, deliberately, before arming.

`-MergeTarget`, `-BaseBranch`, `-MainBranch`, `-PushOnFinish`, and `-NoWorktree`
are **gone** from `launch-showtime.ps1` and `autopro-runner.ps1`. Nothing merges,
so there is nothing to target — a flag that silently does nothing is worse than
one that errors. Passing them now fails loudly, which is the honest outcome.

## `-autopro off` (hard stop)

**Why delete-flag alone feels broken:** the runner only checks `autopro-on`
**between** slices. Mid-slice `claude -p work` keeps going until that process
exits — so the board still looks “on”.

**Use the stop script** (flag + kill runners + orphan claudes):

```powershell
# One repo
pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/stop-autopro.ps1" `
  -Root '<YOUR-REPO-ROOT>'

# Everything on this machine
pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/stop-autopro.ps1" -All
```

Soft-only (wait for current slice, no process kill):

```powershell
Remove-Item -LiteralPath '<Root>/.claude/scratch/autopro-on' -Force -ErrorAction SilentlyContinue
```

## Show Time features

- **MAP honesty parity:** the MAP (Pac-Man) view reads the same `laneHonesty` flags as CLAW — projectors stay visible (LEDGER badge, no fake RUNNING), corpses collapse (DEAD), and MAP runs zero git just like CLAW (see `references/SHOWTIME-HANDOVER.md`)
- **Multi-chat:** second arm joins the same board as the next Chat N lane
- **Monitor Pac** on the left rail (watches lanes, locks onto problems)
- **Timer** estimate from remaining slices × rolling avg; pauses when stalled/paused
- **Stall alarm** after 5 minutes with no progress (toggle on board)
- **Complete alarm** 1950s-style dual-tone ring in the open tab
- **Todo drawer** opposite Pac-Man (list + optional board view); drag/resize
- **Pause tips** rotate from `theater/tips.json`
- **State bus:** `$HOME/.claude/scratch/autopro-theater/`
- **Board auth:** every `/api/*` call (except `/api/health`) needs the per-boot token from `autopro-theater/server.token`; no CORS is granted, so other browser origins can neither read the board nor inject steers

## What the runner guarantees

- Fresh context per slice (new worker process each time)
- Multi-engine auto-detect + pin (`-Engine`, `AUTOPRO_ENGINE`)
- Instant chaining on process exit
- Engine-specific unattended flags (Claude skip-permissions / Codex bypass / Gemini yolo / Grok always-approve)
- Reports complete ONLY when the final check emits `FINAL_CHECK_STATUS=green` (red or unparseable → blocked + handover)
- Stops on `[blocked]`, kill switch (`autopro-on.<sessionId>` deleted), or iteration cap
- Audit trail: `.claude/scratch/autopro.log`
- Show Time heartbeats with **engine + model** credit chips (unless `-NoShowTime`)
- Preflight fails before arm if no worker CLI is installed (`autopro-doctor.ps1`)

## Supervisor v1 (kickstart + needs-you + chat bridge + watch)

Serial AutoPro used to look “stuck” because **ORCH is desk-only** and the arming chat was left out of the loop. Supervisor v1 adds:

| Piece | Behavior |
|--------|----------|
| **Kickstart watchdog** | If the worker **dies within ~12s** with non-zero exit, **retry once** (`KICKSTART_RETRY`). Second early death → `KICKSTART_FAILED` alert. Env: `AUTOPRO_KICKSTART_GRACE_SEC`, `AUTOPRO_KICKSTART_MAX_ATTEMPTS`. |
| **Honest pids** | Heartbeats send `runnerPid` (conductor) + `workerPid` (coding CLI, 0 between slices). Board: flag owner wins column; inherits disk `autopro-worker.pid` for legs. |
| **Needs-you alert** | On blocked / verifier red / timeout / kickstart fail / ledger `[blocked]`: write loud files + OS toast (best-effort). |
| **Chat bridge files** | Repo: `.claude/scratch/AUTOPRO-NEEDS-YOU.md`, `autopro-supervisor-alert.json`, `autopro-chat-inbox.jsonl`. Global: `~/.claude/scratch/autopro-theater/chat-inbox.jsonl` + `needs-you/<sessionId>.md`. |
| **autopro-watch** | `launch-showtime` starts a **minimized** watch console (disable with `-NoWatch`) that polls the inbox and re-toasts NEEDS YOU. |

**ORCH honesty:** the board ORCH head is still **not** the process that spawns workers — the **runner** is. Supervisor + watch make human-needed events hard to miss.

**Perfected operator workflow:** `references/WORKFLOW.md`.

After arm (if you skipped watch):

```powershell
pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/autopro-watch.ps1" `
  -Root "<repo>" -UntilDisarmed -AlsoLog
```

## Honest limits

- Show Time visualizes heartbeats/ledger parse — not full token streams
- Alarms need the browser tab open (Web Audio); OS toast is best-effort
- Chat bridge is **file-based** (and toast) — it does not inject into Cursor/Grok mid-session unless something polls the inbox
- Show Time runs **zero git**: it does not branch, commit, merge, or open a PR. Your work lands wherever the worker committed it — the branch you armed from. Use `ship-epic` to open a PR.
- No worktree isolation: two runners on one repo share a working tree. Single writer per repo.
- Decomposition quality still governs everything

## Tests

```powershell
pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/test-showtime.ps1"
```

## Multi-host install (Cursor / Claude Desktop / Antigravity / Codex / ChatGPT)

`powershell
pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/install-hosts.ps1" `
  -RepoDir "<YOUR-REPO-ROOT>"
`

See `references/HOST-INSTALL.md`. ChatGPT web: paste `references/CHATGPT-CUSTOM-INSTRUCTIONS.md` (also on Desktop as `AUTOPRO-for-ChatGPT.md`).
