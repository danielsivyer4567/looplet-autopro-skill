# AutoPro + Show Time — perfected operator workflow

**One skill.** How big the request is (open ledger slices) picks concurrency — unless you force it:

| You say | Mode | Launcher |
|---------|------|----------|
| `-autopro` | **auto** — open slices &lt; 12 → serial, ≥ 12 → ultra | `launch-autopro.ps1` |
| `-autopro serial` | force serial | → `launch-showtime.ps1` |
| `-autopro ultra` / `parallel` | force parallel | → `launch-ultra.ps1` |
| `-autopro off` | stop | `stop-autopro.ps1` |

Threshold: `-SerialMaxSlices` (default **12**) or `AUTOPRO_SERIAL_MAX_SLICES`.

This is the **one happy path** that keeps context windows clean, keeps you out of
babysitting, and makes failures impossible to miss.

## The three problems this solves

| Pain | Cause | Fix |
|------|--------|-----|
| Context blowout | One long agent chat does every slice | **Serial AutoPro**: fresh worker process per slice |
| Slow + needs attention | You re-drive each slice by hand | **Runner loop** + unattended engine flags |
| Silent glitch / “stuck” | ORCH is a desk glyph; arming chat stops; board lies about pids | **Supervisor + watch + honest heartbeats** |

## Cast (who does what)

| Role | What it actually is |
|------|---------------------|
| **You** | Approve ledger once; arm once; only intervene on NEEDS YOU / complete handover |
| **Arming chat** | Runs `launch-showtime.ps1`, prints TV card, **stops** (does not also run `work`) |
| **Runner** (`autopro-runner.ps1`) | Conductor. Spawns workers, kickstarts, final check, handover |
| **Worker** | Fresh `claude`/`codex`/`gemini`/`grok` process for **one** slice |
| **Show Time** (`:8770`) | Cinema only — zero git. Shows lanes, steers, heartbeats |
| **ORCH glyph** | Housing / fleet desk on the board — **not** a process that spawns workers |
| **Watch** (`autopro-watch.ps1`) | Polls chat-inbox + needs-you; minimized console + OS toast |

## Arm (once)

Preconditions: ledger exists, `Approved: yes`, at least one worker CLI, independent final gate (or `-AllowModelOnlyFinalCheck`).

```powershell
$skill = Join-Path $HOME '.claude/skills/autopro/scripts'
$root  = 'C:\repos\looplet-producer'   # repo with .claude/scratch/ledger.md

# Auto (default) — size of ledger picks serial vs ultra
pwsh -NoProfile -File (Join-Path $skill 'launch-autopro.ps1') `
  -Root $root -RepoDir $root `
  -AllowDangerousSkipPermissions -IAcceptUnattendedRisk

# Force either mode when you know better than the heuristic
# … -Mode serial
# … -Mode ultra -MaxConcurrency 4
```

That single command (serial path when auto picks it or you force serial):

1. Writes per-session `autopro-on.<sess_…>`
2. Ensures Show Time server + registers the lane
3. Opens the board in a browser
4. Detaches the **runner**
5. Starts **autopro-watch** (minimized) unless `-NoWatch`
6. Prints the TV card + `SHOWTIME_URL` + `NEEDS_YOU` / `CHAT_INBOX` paths

Then **stop typing in the arming chat**. The runner owns the loop.

## While it runs

| Surface | Use |
|---------|-----|
| Board `http://127.0.0.1:8770/` | Visual progress, steers, stall alarm |
| Minimized **autopro-watch** window | NEEDS YOU lines + log highlights |
| `.claude/scratch/autopro.log` | Full audit trail |
| `.claude/scratch/AUTOPRO-NEEDS-YOU.md` | Latest human-required alert |
| `.claude/scratch/autopro-chat-inbox.jsonl` | Machine events (append-only) |

### Board honesty (pids)

Heartbeats send:

- `runnerPid` — conductor (always the runner while armed)
- `workerPid` — live coding CLI (**0** between slices)
- `pid` — worker if coding, else runner

Server enrichment:

- **Flag owner** wins the column (twins never steal legs via shared disk pid)
- Owner inherits `autopro-worker.pid` for coding legs
- `workerAlive` = coding process; `pidAlive` = armed (runner or worker)

## When it needs you

Supervisor writes loud files + toast + board sentinel on:

- kickstart failed (worker died twice in grace)
- worker timeout
- blocked ledger slice / verifier red exhausted
- final check not green

**Do not ignore** `AUTOPRO-NEEDS-YOU.md`. Fix the cause (ledger, env, engine), then re-arm or unstick the slice.

Manual watch if you used `-NoWatch`:

```powershell
pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/autopro-watch.ps1" `
  -Root C:\repos\looplet-producer -UntilDisarmed -AlsoLog
```

## When it finishes

- Board → complete (handover delivered)
- `.claude/scratch/SHOWTIME-HANDOVER.md` — full report + **red STILL TO DO** (wiring AutoPro never ships)
- Chat inbox may log `AUTOPRO COMPLETE — READ HANDOVER`
- Flags cleared / watch exits with `-UntilDisarmed`

Still your job after green: PR (`ship-epic`), secrets, Supabase/edge, deploy — listed in STILL TO DO.

## Stop

```powershell
pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/stop-autopro.ps1" `
  -Root C:\repos\looplet-producer
```

## Hard rules (do not “improve” these away)

1. **Zero git in Show Time** — no worktree, branch, commit, merge from theater scripts.
2. **Single writer per repo** — one runner; parallel epics = separate checkouts you create yourself.
3. **Fresh process per slice** — never one long chat for the whole ledger.
4. **ORCH is not the conductor** — the runner is; supervisor makes the runner reliable and notifies you.
5. **Chat bridge is files + toast + watch** — nothing injects into Cursor/Grok mid-session unless something polls the inbox.

## Offline proofs

```powershell
pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/test-autopro-supervisor.ps1"
node "$HOME/.claude/skills/autopro/scripts/test-worker-ownership.mjs"
node "$HOME/.claude/skills/autopro/scripts/test-legs-honesty.mjs"
node "$HOME/.claude/skills/autopro/scripts/test-lane-honesty.mjs"
```

## Related

- `SUPERVISOR-V1.md` — kickstart + needs-you details  
- `SHOWTIME-HANDOVER.md` — cold handover  
- `APPROVE-ARM-CONTRACT.md` — board Approve vs arm  
- `BULLETPROOF.md` — multi-engine checklist  
