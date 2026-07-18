 > **Superseded for multi-repo:** see `FLEET-HANDSHAKE.md` (party rule — one ORCH per ledger).

# Show Time lane lifecycle (no twin chats, no lost finish)

## Identity (why SA-3 vs SA-5 looked “the same”)

| Field | Role |
|-------|------|
| `sessionId` | Stable arm id (`sess_…`). One runner owns one. |
| `ledgerKey` | **Immutable** hash of ledger **at arm time**. Primary dedupe key. |
| `ledgerHash` | **Current** ledger content — **drifts** as slices flip to `[done]`. Never sole dedupe. |
| `ledgerTitle` | Human epic name. With git root, catches same job when hash drifted. |
| `SA-N` / `Chat N` | **Display only** (lane number). Changing branch does **not** create a new identity. |
| `branch` | Usually `showtime/sess_…` — unique per arm, useless for dedupe. |

**Twins happen when** a second arm mints a new `sessionId` with a **fresh** ledger hash from main while the first worktree’s hash already drifted — hash-only match fails.

**Board now rejects/attaches** when any of these match an open lane:
1. same `ledgerKey`
2. same current/original `ledgerHash`
3. same **git root** + same **title**
4. same worktree-stripped path + title

Result: `already_on_board` → **attach**, do not spawn Chat N+1.

## Are twins writing double code?

**Yes, if both runners are live.** Each has its own worktree/branch and will commit into that worktree. Dedupe on the board does **not** kill the second process — stop the extra runner:

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\autopro\scripts\stop-autopro.ps1" -Root '<repo>'
# or stop one session by deleting: .claude/scratch/autopro-on.<sessionId>
```

Keep the older/canonical `sessionId` worktree; discard the twin after merge or delete.

## After work is done (happy path)

Autopro runner when pending=0, in-progress=0:

1. **Final check** — must print `FINAL_CHECK_STATUS=green`
2. **Handover** if red → board `blocked`, worktree kept
3. If green → **scoped commit → merge into base/main → prune worktree**
4. Board **`complete`** then lane auto-wipes

Manual finish when runner **stalled** but ledger 100% done:

```powershell
# verify in worktree, then:
pwsh -File ...\showtime-worktree.ps1 -Action finish -RepoDir '<repo>' -SessionId 'sess_…'
pwsh -File ...\theater-register.ps1 -Action complete -SessionId 'sess_…' -RepoDir '<repo>' -Root '<repo>'
pwsh -File ...\stop-autopro.ps1 -Root '<repo>'
```

## Fallbacks / reconnect

| Situation | What should happen |
|-----------|-------------------|
| Board process died | `theater-register -Action ensure` (singleton) |
| Heartbeat 404 after restart | Runner re-registers **same sessionId**; rematerializes if join was approved |
| Second arm same epic | Board returns `already_on_board` — **do not** launch second runner |
| Stalled lane, work continuing | Heartbeat again; or operator Nudge; do **not** re-arm new session |
| Stalled lane, work finished | Manual final check → finish merge → complete |
| Operator reloads Chrome | Board is local token inject; SYNC / hard refresh |

## Operator rules

1. **One arm per ledger title per git root.**  
2. Approve join **once**.  
3. Open `http://127.0.0.1:8770/` in your signed-in Chrome (`-NoBrowser` on launch).  
4. When Chat is done: verify → handover → merge/prune → complete — not “leave stalled forever”.  
5. If you see two SA cards for the same title: stop the newer runner, unregister the twin lane, keep one worktree.
