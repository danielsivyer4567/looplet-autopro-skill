# MAP (Pac-Man) vs CLAW — honesty gap list

**Epic:** Show Time MAP honesty parity  
**Source:** `theater/index.html` (`renderLanes` vs `renderClaw` / shared helpers)  
**Date:** 2026-07-15 · SC-01 audit only (no behavior change)

Server already enriches sessions with: `isWorkerOwner`, `pidAlive`, `workerAlive`,
`corpse`, `ledgerProjector`, `twinOf` (`worker-ownership.mjs` → `listSessionsEnriched`).

CLAW **consumes** those flags. MAP **mostly ignores** them.

---

## What CLAW does (control)

| Concern | CLAW behavior |
|---------|----------------|
| Fleet identity | `groupSessionsByFleet` → one column per **repo root** |
| ORCH head | Big ORCH invader under Previous notes; “talk to ORCH only” |
| Coding writer | `sessionHasWorker` requires owner + live pid; `legsShouldRun` for legs |
| Other ledgers same root | `ledgerProjector` → full SC stack, badge LEDGER, **no** invader/legs |
| Dead junk | `corpse` → collapsed strip; Purge dead |
| Single invader | One agent per SA column on **active** SC only; never on done cards |
| Mission | Embedded per fleet head, scoped to that group’s sessions |

---

## What MAP does today (`renderLanes`)

| Concern | MAP behavior | Gap |
|---------|--------------|-----|
| Session list | **Flat** `sessions.map` — no fleet grouping | No MAIN/SIDE headers; mixed roots look like peers |
| Owner / twin | Uses `s.status` + ledger % only | Can show **RUNNING** pac for projectors/corpses |
| `isWorkerOwner` | **Not read** | Twin projectors look like coding writers |
| `ledgerProjector` | **Not read** | No LEDGER badge / projector copy |
| `corpse` | **Not read** | Dead lanes still get pellets + ghosts + pac |
| Pac “coding” | `status===running` or slice in-progress → RUNNING | No pidAlive / owner gate |
| Ghost | Queued/stalled/blocked **or** any incomplete prog | Ghost even on healthy owner lanes (decorative, not honesty) |
| CLEAR! | done≥total from ledger counts | OK for progress; can CLEAR on projector with full ledger |
| Fleet headers | None | Differs from CLAW multi-fleet row |
| ORCH | Per-lane mission chip only (`laneMissionHtml`) | No shared ORCH desk glyph |
| Nudge target | Click lane → `setSelectedAgent` | **OK** if sessionId correct (verify SC-05) |
| Purge dead | Global button works for both views | OK (session bus shared) |

---

## Priority fix order (for SC-02+)

1. **SC-02** — `laneHonesty(s)` shared helper from server flags (single source for MAP+CLAW labels).  
2. **SC-03** — MAP section headers via `groupSessionsByFleet`.  
3. **SC-04** — Wire pac/ghost/meta to honesty kinds (no fake RUNNING on projectors).  
4. **SC-05** — Confirm MAP click → dock nudge still hits that sessionId.  
5. **SC-06** — Offline suite green.  
6. **SC-07** — Arm soak; watch CLAW, flip MAP.  
7. **SC-08** — Docs.

---

## Non-goals (this epic)

- Redesigning Pac art / pellet physics  
- Git push from the board  
- Removing CLAW as primary theater  

---

## Quick human check

With one live owner session on the board:

| View | Expect after SC-04 |
|------|---------------------|
| CLAW | ORCH + one SA with legs if coding |
| MAP | One fleet section; pac RUNNING only if owner+coding; projectors say LEDGER |

*SC-01 done — research only.*
