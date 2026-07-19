# AutoPro Supervisor v1

## Problem

Serial AutoPro looked flawless only when nothing failed. In practice:

1. **ORCH** on Show Time is a **desk glyph**, not a process that watches workers.
2. The **runner** spawns workers, but early death (argv fail, missing binary, instant crash) looked like “nothing started.”
3. The **arming chat** was told to stop — so blocked slices never came back for human resolution.

## Solution (v1)

| Component | File | Job |
|-----------|------|-----|
| Decision + notify + inbox | `scripts/autopro-supervisor.ps1` | Pure helpers + OS toast + files |
| Kickstart + wire | `scripts/autopro-runner.ps1` | Retry once; alert on block/timeout |
| Offline green | `scripts/test-autopro-supervisor.ps1` | `SUPERVISOR_CHECK=green` |

### Kickstart

1. Spawn worker, write `autopro-worker.pid`, set `CurrentWorkerPid`, heartbeat with **workerPid + runnerPid**.
2. Wait grace (`AUTOPRO_KICKSTART_GRACE_SEC`, default **12**).
3. If still running → normal loop (heartbeats every 45s, max slice timeout).
4. If exited non-zero in grace → **KICKSTART_RETRY** once.
5. Second early non-zero → **KICKSTART_FAILED** + needs-you alert.
6. Early exit **0** → short success (no retry, no alert).
7. On worker exit → clear `CurrentWorkerPid` + delete pid file (board: armed runner, not coding).

### Board ownership honesty

- `autopro-on.<sessionId>` **flag owner wins** the column (twins cannot steal legs via shared disk pid).
- Owner inherits live disk `autopro-worker.pid` for coding legs.
- `workerAlive` = coding CLI; `pidAlive` = runner or worker (lane still armed between slices).

### Needs-you / chat bridge

On blocked outcomes (via `Write-Handover` for non-`complete`, plus kickstart/timeout):

- `<repo>/.claude/scratch/AUTOPRO-NEEDS-YOU.md`
- `<repo>/.claude/scratch/autopro-supervisor-alert.json`
- `<repo>/.claude/scratch/autopro-chat-inbox.jsonl` (append)
- `~/.claude/scratch/autopro-theater/chat-inbox.jsonl`
- `~/.claude/scratch/autopro-theater/needs-you/<sessionId>.md`
- OS toast (BurntToast / NotifyIcon / osascript — best effort)
- **autopro-watch.ps1** (started by `launch-showtime` unless `-NoWatch`) polls the inbox

### What v1 does **not** claim

- Does not inject messages into Cursor/Claude/Grok UIs (poll the inbox / use watch).
- Does not make ORCH a coding agent.
- Does not auto-unblock `[blocked]` ledger rows (human must edit).
- Does not replace Show Time steers — board nudge still works for live runners.

## Operator after arm

`launch-showtime` opens a **minimized** watch console by default. Manual:

```powershell
pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/autopro-watch.ps1" `
  -Root C:\repos\looplet-producer -UntilDisarmed -AlsoLog
```

Or open `AUTOPRO-NEEDS-YOU.md` when the board stalls. Full path: `references/WORKFLOW.md`.

## Handover report (end of run)

Every terminal outcome (complete **or** blocked) writes  
`<repo>/.claude/scratch/SHOWTIME-HANDOVER.md` with:

1. **Orchestrator report** — outcome, engine, tokens, notes  
2. **Slice inventory** — table of every SC status  
3. **Incomplete / missing** — pending, in-progress, blocked  
4. **Final check tail** + recent log  
5. **Required follow-up**  
6. **Red STILL TO DO block (always last)** — HTML red panel including:
   - unfinished slices  
   - ledger “Out of scope” / “After 100%” lines  
   - wiring hints: Supabase, edge functions, Cloudflare, env/secrets, CORS,  
     migrations, webhooks, OAuth, DNS, CI/CD, deploy, Engine pin, ACE-Step, e2e, PR  

On **complete**, chat bridge writes `AUTOPRO COMPLETE — READ HANDOVER` (not “needs you”),  
but the red STILL TO DO section still lists production wiring AutoPro never ships.
