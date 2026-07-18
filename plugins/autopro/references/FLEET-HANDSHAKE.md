# Fleet handshake — the party rule (shipped contract)

> **Not documentation-only.** Runtime enforces fleets in `theater-server` + `fleet-core.mjs`.

## The party (one sentence)

**You may join the board with workers only if you bring an orchestrator for your one ledger; when done you commit (if set), leave a handover, and clear your fleet.**

## Metaphor

| Party | Board |
|-------|--------|
| Venue | `theater-server` on `http://127.0.0.1:8770/` |
| Guest | One **fleet** = one home repo + **one ledger** |
| Manager | **ORCH** for that fleet only |
| Workers | **SA-1…SA-N** under *that* ORCH (local numbers) |
| Host desk | Operator; talks to each fleet’s ORCH, not raw workers |

**Forbidden:** six different ledgers under one global ORCH.

```
[ ORCH · repo A · ledger X ]     [ ORCH · repo B · ledger Y ]
         │                                │
    SA-1   SA-2                      SA-1   SA-2
```

## Handshake steps

1. **Join** — `request-join` / arm → creates **fleet** + attaches worker(s).  
2. **Approve** (join gate) — operator lets the fleet on the canvas.  
3. **Work** — workers heartbeat; ORCH surface carries notes/steers.  
4. **Nudge / buttons** — tagged with `fleetId`; durable line in  
   `<primaryRepoPath>/.claude/scratch/showtime-inbox.jsonl`.  
5. **Leave** — final check → commit policy → handover → `leave` fleet (workers cleared).

## API sketch

| Action | Path |
|--------|------|
| List fleets | `GET /api/fleets` |
| Ensure / attach fleet | `POST /api/fleets` |
| Leave party | `POST /api/fleets/:id/leave` |
| Register worker | `POST /api/sessions` (must resolve to a fleet; auto-ensure on arm) |

## Selectable agent (operator UI)

On the board ORCH desk / OPS rail you **must pick** which agent you are talking to:

- **Agent** dropdown (desk) and **fleet-grouped chips** (OPS)  
- Selection persists in `localStorage` (`st-selected-agent`)  
- **Nudge / Comment / Steer** go only to the **selected** worker session  
- Selecting **ORCH** targets that fleet’s primary worker (MVP: one runner per fleet)  
- Desk subtitle shows: `targeting SA-N · repo` (never “all sub-agents”)

Proof: `node scripts/test-selectable-agent.mjs` (theater must be up).

## Paste for other chats

```text
SHOW TIME PARTY RULE
- Board is a shared venue (127.0.0.1:8770), not your repo’s owner.
- You MUST join as a FLEET: one ledger + one ORCH + your workers under that ORCH.
- Never dump your ledger under someone else’s orchestrator.
- Same ledger again → attach existing fleet (no twin ORCH).
- Operator SELECTS an agent on the board before Nudge/Steer — messages never go to all SA.
- Nudge/steers go to YOUR fleet and YOUR .claude/scratch/showtime-inbox.jsonl.
- When done: verify → commit if configured → handover note → leave/clear fleet.
Arm:
  theater-register -Action request-join  (or launch-showtime)
  then operator Approves the join on the board.
```
