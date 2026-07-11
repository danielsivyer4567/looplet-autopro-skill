---
name: autopro
description: "One-key autonomous ledger execution with optional Show Time visual board (Looplet). After a ledger exists and is approved, `-autopro` (or `/autopro`) launches a background runner that executes every remaining slice as its own FRESH `claude -p` session (true clean context per slice), opens Show Time in the browser for multi-chat progress, loops until 100% done — then runs `check`, reports, and disarms. `-autopro off` stops it. Pairs with `ledger` and `work`."
trigger: /autopro
---

# autopro + Show Time (Looplet)

`work` does one slice, commits, and stops so you can `/clear` and run `work`
again. `autopro` removes both manual steps: you type `-autopro` **once**, and a
background runner drives the ledger to completion on its own.

**Show Time** is the optional visual board (v2): arcade **horizontal** Pac-Man
lanes per chat, a left **monitor Pac** that watches/locks onto problems, Mission
Status modal, right ops sidebar (in-flight, sentinel, checklist, steer), bottom
per-chat notes/questions ledges, token-saver + tok/s + lines/tok·min stats.

Default board port **8770** (8766 is often Electron). Live URL is emitted **once** on the TV card / `SHOWTIME_URL` after arm (reads `server.port`).  
Credit: **Show Time - Looplet**.

## Why a background runner

Claude cannot clear its own context. Each `claude -p "work"` is a brand-new
session = genuinely clean context. The runner loops one slice per process.

Canonical scripts live in this skill:

| Script | Role |
|--------|------|
| `scripts/launch-showtime.ps1` | Arm flag + worktree + Show Time + detach runner |
| `scripts/autopro-runner.ps1` | Slice loop + scoped commits + finish merge/prune |
| `scripts/showtime-final-check.ps1` | Merge gate: decode `claude -p` JSON → green/red verdict |
| `scripts/showtime-worktree.ps1` | create / finish (merge) / prune worktrees |
| `scripts/showtime-scoped-commit.ps1` | Commit only paths inside one worktree |
| `scripts/theater-server.mjs` | Localhost Show Time server (port 8770+) |
| `scripts/theater-register.ps1` | ensure / register / heartbeat / complete |
| `scripts/showtime-open-board.ps1` | **Always** open board URL in browser; companion/extension hooks additive |
| `scripts/test-showtime.ps1` | Automated board tests (no claude) |
| `theater/index.html` | Show Time UI |
| `theater/tips.json` | Pause-screen rotating tips |

Always launch with **`pwsh`**, not Windows PowerShell 5.1.

## When you type `-autopro`

1. **Preconditions.** Read `.claude/scratch/ledger.md`.
   - No ledger → "Run `ledger` first." Stop.
   - `Approved:` is not `yes` → "Approve the ledger first." Stop.
   - Prefer: if `autopro-on` already exists and a runner is healthy, say already
     armed (still open Show Time URL if useful).
2. **Arm + Show Time + launch** (adjust paths to the epic worktree):

   ```powershell
   $skill = Join-Path $env:USERPROFILE '.claude\skills\autopro\scripts'
   $root  = '<YOUR-REPO-ROOT>'   # scratch + flag root
   $repo  = $root                                  # ledger lives here
   & pwsh -NoProfile -File (Join-Path $skill 'launch-showtime.ps1') `
     -Root $root -RepoDir $repo
   ```

   That script:
   - writes `autopro-on`
   - creates an **isolated git worktree** + branch `showtime/<sessionId>`
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
   Get-Content ".claude\scratch\autopro.log" -Wait
   ```


## Merge + automatic prune (after finish)

| Step | Behavior |
|------|----------|
| Arm | Worktree at `../.worktrees-showtime/<sessionId>` on `showtime/<sessionId>` |
| Each slice | Scoped commit **only** in that worktree |
| Ledger complete + check | Merge into chosen target, then prune worktree + branch |
| Extra sweep | Prunes other READY showtime trees (already merged + clean) |

### Where mini-branches land (`-MergeTarget`)

| Option | Meaning |
|--------|---------|
| **`base`** (default) | All chats merge back into the **one epic branch** you armed from |
| **`main`** | Each finished ledger/session merges into **`main`** (or `-MainBranch`) |

```powershell
# Fold into epic line
& pwsh -File (Join-Path $skill 'launch-showtime.ps1') -Root $root -RepoDir $repo -MergeTarget base

# Each chat → main after check
& pwsh -File (Join-Path $skill 'launch-showtime.ps1') -Root $root -RepoDir $repo -MergeTarget main
```

Manual prune leftovers:

```powershell
pwsh -File "$env:USERPROFILE\.claude\skills\autopro\scripts\showtime-worktree.ps1" `
  -Action prune -RepoDir '<repo>' -StaleDays 7
```

Opt out of isolation (not recommended): `launch-showtime.ps1 -NoWorktree`.

## `-autopro off` (hard stop)

**Why delete-flag alone feels broken:** the runner only checks `autopro-on`
**between** slices. Mid-slice `claude -p work` keeps going until that process
exits — so the board still looks “on”.

**Use the stop script** (flag + kill runners + orphan claudes):

```powershell
# One repo
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\autopro\scripts\stop-autopro.ps1" `
  -Root '<YOUR-REPO-ROOT>'

# Everything on this machine
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\autopro\scripts\stop-autopro.ps1" -All
```

Soft-only (wait for current slice, no process kill):

```powershell
Remove-Item -LiteralPath '<Root>\.claude\scratch\autopro-on' -Force -ErrorAction SilentlyContinue
```

## Show Time features

- **Multi-chat:** second arm joins the same board as the next Chat N lane
- **Monitor Pac** on the left rail (watches lanes, locks onto problems)
- **Timer** estimate from remaining slices × rolling avg; pauses when stalled/paused
- **Stall alarm** after 5 minutes with no progress (toggle on board)
- **Complete alarm** 1950s-style dual-tone ring in the open tab
- **Todo drawer** opposite Pac-Man (list + optional board view); drag/resize
- **Pause tips** rotate from `theater/tips.json`
- **State bus:** `%USERPROFILE%\.claude\scratchutopro-theater\`
- **Board auth:** every `/api/*` call (except `/api/health`) needs the per-boot token from `autopro-theater\server.token`; no CORS is granted, so other browser origins can neither read the board nor inject steers

## What the runner guarantees

- Fresh context per slice (`claude -p`)
- Instant chaining on process exit
- `--dangerously-skip-permissions` for unattended runs
- Merges ONLY when the final check emits `FINAL_CHECK_STATUS=green` (red or unparseable → blocked + handover, worktree preserved, no merge)
- Stops on `[blocked]`, kill switch (`autopro-on.<sessionId>` deleted), or iteration cap
- Audit trail: `.claude/scratch/autopro.log`
- Show Time heartbeats (unless `-NoShowTime`)

## Honest limits

- Show Time visualizes heartbeats/ledger parse — not full token streams
- Alarms need the browser tab open (Web Audio)
- Finish **merges locally into base** — it does not open a GitHub PR (`ship-epic` is separate if you want origin/main PR auto-merge)
- Merge conflicts leave the worktree for you; re-run `finish` / `prune` after resolve
- Decomposition quality still governs everything

## Tests

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\autopro\scripts\test-showtime.ps1"
```

## Multi-host install (Cursor / Claude Desktop / Antigravity / Codex / ChatGPT)

`powershell
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\autopro\scripts\install-hosts.ps1" `
  -RepoDir "<YOUR-REPO-ROOT>"
`

See `references/HOST-INSTALL.md`. ChatGPT web: paste `references/CHATGPT-CUSTOM-INSTRUCTIONS.md` (also on Desktop as `AUTOPRO-for-ChatGPT.md`).
