# Show Time (Looplet) — controls

Board: `http://127.0.0.1:8770/` (hard-refresh or **Shift+SYNC** after updates)

**Full product handover:** `references/HANDOVER-SHOWTIME-UI.md`

## Mental model

- **You talk only to ORCH** (fleet head).  
- **SA-N = Chat N = lane N** — sub-agents under ORCH.  
- Questions: ORCH asks **on behalf of** SA-N; reply to ORCH.

## Views + connection (top bar)

| Control | What |
|---------|------|
| **📁 HANDOVERS** | One folder → modal of all notes · **Copy** / **Copy all** |
| **LIST / MAP / CLAW** | Same session data; `localStorage.st-view` |
| **SYNC** | Force reconnect + cache-bust |
| **Shift+SYNC** | Hard-reload board HTML |
| **Last connected / AUTO 2s** | Connection poll (no-store) |

## Mission status

| Mode | Where |
|------|--------|
| **MAP** | On **each** Pac card (matches track width) |
| **LIST** | Fleet strip above stage |
| **CLAW** | **Inside** LOOPLET FLEET · ORCHESTRATOR head |

## Canvas

| Action | How |
|--------|-----|
| **Pan** | Drag empty stage (MAP/CLAW) |
| **Zoom** | Wheel · `−` / `+` · 20%–200% |
| **Fit** | Frames content (CLAW: width-first, readable min scale) |
| **Reset** | Default pan/zoom · or double-click empty |

CLAW: bezier **node strings** ORCH → branches; coral **pixel invader** claws.

## Rails

- **Left:** Stats · history  
- **Right:** OPS · tabs `SA-N` · “Talk to ORCH only”

## Bottom — ORCH desk

- **Max width = ORCH head** (`--orch-w` ≈ 360px), centered — **not** full screen.  
- Sub-agent panels stack inside that width.  
- Copy: **ORCH asks · on behalf of SA-N** · **Reply ORCH**.  
- Toggle: Show/Hide **ORCH desk**.

## Handovers + wipe

| Event | Behavior |
|-------|----------|
| **Complete** | Handover → outbox + folder · wipe lane ~8s |
| **Arm preflight** | Stale runners · wipe complete/stale lanes · flush pending notes |
| **stop-autopro** | Kill processes · preflight wipe board |

Outbox: `%USERPROFILE%\.claude\scratch\autopro-theater\handover-outbox.md`

## Merge + worktree (isolation)

| Stage | What |
|-------|------|
| **Arm** | Worktree `showtime/<sessionId>` |
| **Slice** | `claude -p` in worktree · scoped commit |
| **Finish** | Merge + prune |

`-MergeTarget base` (default) or `main` — see `HANDOVER-SHOWTIME-UI.md`.

```powershell
$launch = Join-Path $env:USERPROFILE '.claude\skills\autopro\scripts\launch-showtime.ps1'
$root = '<YOUR-REPO-ROOT>'
pwsh -File $launch -Root $root -RepoDir $root -MergeTarget base
```

## Stop

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\autopro\scripts\stop-autopro.ps1" `
  -Root '<YOUR-REPO-ROOT>'
# or -All
```

Soft-only: delete `.claude\scratch\autopro-on` (mid-slice `claude -p` still finishes).
