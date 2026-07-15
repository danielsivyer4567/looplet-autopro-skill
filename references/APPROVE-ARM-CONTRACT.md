# Approve → Arm contract (Door A / Door B)

**Product:** Show Time is a **projector / housing**, not the factory.  
Work happens **inside each repo** (ledger + runner). The board only displays progress.

**Status:** Implemented in code (`theater-server` + `arm-on-approve.ps1`).  
**Epic lock:** Offline proof script must print `READY_CHECK=green` (`scripts/prove-approve-arm-offline.ps1`).  
Human flips ledger `READY: yes` before live Approve→Arm demos.

**Cold handover:** `references/SHOWTIME-HANDOVER.md`

---

## Board hierarchy (CLAW)

```
ORCH head (big invader under Previous notes)  ← humans talk HERE only
   |  strings
   +-- SA-1 vertical SC stack   ← one worker works DOWN this list
   +-- SA-2 vertical SC stack
```

| Glyph | Where | Rule |
|-------|--------|------|
| **ORCH** (labeled invader) | Fleet head card, under Previous notes | Desk / attention — not a code worker |
| **Worker** (one per SA column) | **Active SC only** | Done cards: ring only, **never** a worker. Pending: empty. |
| **Legs moving** | That active SC | Live pid **coding** |
| **Stiff on active SC** | That active SC | Hold / clash / issue + **reason** |
| **No worker** | — | Unarmed, or between slices |

Join alarm: **one short sound per new ledger** (not multi-round spam).

---

## Two doors (never confuse them)

| Door | Name | What it does | What it does **not** do |
|------|------|----------------|-------------------------|
| **A** | **Join gate** | Puts a **lane on the board**. Loud OS alarm + banner. Operator **Approve** / **Deny**. | Does not write code. Does not by itself mean “workers running.” |
| **B** | **Arm** | Starts **autopro** in a **specific repo** (`launch-showtime` → runner → `work` slices). | Does not replace the human Approve on Door A. |

### The product rule (once and for all)

> **Board Approve (Door A) opens Door B** when the join is a real repo with `Approved: yes` ledger.  
> Approve is **operator consent** for unattended arm in that repo.

```
Join request → LOUD alarm + board banner
     ↓
Approve (human)  = Door A open
     ↓
Lane on board (housing)
     ↓
AUTO-ARM          = Door B open  (arm-on-approve.ps1 → launch-showtime.ps1)
     ↓
autopro-on + runner PID → slices → legs may move
```

---

## Legs / claw honesty

| Signal | Meaning |
|--------|---------|
| **Legs moving** | Live worker **pid** is coding on that SC |
| **Stiff on active SC** | Live pid but hold / clash / stagnant (reason required) |
| **No invader on done SCs** | Completed work — worker moved on |
| **Full green ring** | Slice **done** (history), not “working now” |
| **ORCH head glyph** | Human contact point; SAs report up |

**Rule of thumb:** if the legs aren’t moving, it isn’t coding. One worker per SA column, working down the list.

---

## Multi-fleet isolation

- **One fleet column per repo / ledger** (e.g. Looplet Producer MAIN, extension SIDE).
- Never hang `ai-sidebar` SA cards under a Producer head (or the reverse).
- Group key: git root of `repoPath` / fleet identity — not “whatever joined last.”
- Junk joins (`sound-test`, `LOUD-`, `BLAST-`, probe titles) **never arm** and should be purged.

---

## Scripts (canonical)

| Script | Role |
|--------|------|
| `scripts/arm-on-approve.ps1` | Door A → Door B bridge after Approve |
| `scripts/launch-showtime.ps1` | Arm flag + detach runner (+ board unless `-NoBrowser`) |
| `scripts/autopro-runner.ps1` | Slice loop (worker commits) |
| `scripts/theater-server.mjs` | Board API, join gate, auto-arm hook, purge-junk |
| `scripts/stop-autopro.ps1` | Hard stop runners for a Root |

### Kill switches

| Switch | Effect |
|--------|--------|
| `SHOWTIME_AUTO_ARM=0` | Approve still boards the lane; **no** auto-arm |
| `stop-autopro.ps1 -Root <repo>` | Kill runners + flags for that repo |
| Deny on join | Never boards; never arms |

---

## When arm is skipped (honest)

- No `repoPath` / path missing on disk  
- Ledger missing or not `Approved: yes`  
- Junk session id / title  
- Debounce (same repo re-approved within ~20s)  
- Runner **already live** for that Root → `already_armed` (no twin)

---

## Logs (debug, not vibes)

| Log | Where |
|-----|--------|
| Join alarm | `%USERPROFILE%\.claude\scratch\autopro-theater\join-alarm.log` |
| Arm bridge | `%USERPROFILE%\.claude\scratch\autopro-theater\arm-on-approve-bridge.log` |
| Per-repo arm | `<repo>\.claude\scratch\arm-on-approve.log` |
| Autopro runner | `<repo>\.claude\scratch\autopro.log` |

---

## Agent rules

1. Do **not** claim workers are running from Approve alone — check **pid / armStatus / autopro-on**.  
2. Do **not** arm Show Time for demos while epic `READY: no`.  
3. Do **not** invent a second runner on a Root that already has a live `autopro-runner`.  
4. Board is cinema; **repo ledger is truth**.

---

*Contract written for SC-R01 — Approve→Arm + multi-fleet housing epic.*
