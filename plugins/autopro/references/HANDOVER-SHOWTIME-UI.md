# Handover: Show Time UI (current)

**Date:** 2026-07-10  
**Product:** Show Time · Looplet (autopro visual board)  
**Live board:** `http://127.0.0.1:8770/`  
**Skill root:** `%USERPROFILE%\.claude\skills\autopro\`  
**Repo mirror:** `<loopletai>/.claude/skills/autopro/`  
**Server:** `scripts/theater-server.mjs` · **UI:** `theater/index.html`  
**Extension embed:** iframe this board — do **not** reimplement MAP/LIST/CLAW in React for v1  

Hard-refresh after UI changes, or **Shift+SYNC** on the board.

---

## TL;DR — mental model

```
YOU (operator)
    │
    ▼  talk only here
┌─────────────┐
│    ORCH     │  LOOPLET FLEET · HEAD ORCHESTRATOR
│  (fleet)    │  Mission Status embedded in head (CLAW)
└──────┬──────┘
       │  node strings (bezier) · SA-N = Chat N
       ▼
  SA-1 · SA-2 · … · SA-N     sub-agents (one per lane/chat)
```

| Rule | Detail |
|------|--------|
| **Talk to** | **ORCH only** — never address a sub-agent directly |
| **IDs** | **SA-N ≡ Chat N ≡ lane N** (same number) |
| **Questions** | ORCH asks **on behalf of** SA-N; answers go to ORCH, ORCH tells SA-N |
| **Board wipe** | Complete → handover → wipe lane ~8s; stale/kill → handover + wipe on preflight |

---

## 1. Board chrome (what you see)

### 1.1 Top bar

| Element | Behavior |
|---------|----------|
| **📁 HANDOVERS** (left) | **One** larger folder button (count badge). Click → modal with **all** notes. Per-note **Copy** + **Copy all**. Esc / backdrop closes. |
| **SHOWTIME** title | Brand |
| **LIST / MAP / CLAW** | View mode; persisted `localStorage.st-view` |
| **SYNC** | Force connection + cache-bust; **Shift+SYNC** = hard-reload board HTML |
| **Last connected / AUTO 2s** | Connection probe; auto poll every 2s (no-store) |
| **1UP / HIGH** | Score strip (right) |
| **Needs banner** | `ORCH holding for SA-N · Chat N — "…"` → opens ORCH desk |

### 1.2 Views

| View | Behavior |
|------|----------|
| **MAP** | Pac-Man lanes; pan/zoom; Fit. Mission status **per Pac card** (same width as track). Lanes narrow (`~380px` column). |
| **LIST** | Dense ledger-style sections per sub-agent. Fleet mission strip at top of board. |
| **CLAW** | Fleet tree: **ORCH head** (mission embedded) → **SVG node strings** → branch cards. **Pan/zoom** (same tools as MAP). Pixel **invader** glyph (coral `#e07a5f`) for claws + ORCH. |

### 1.3 CLAW layout rules

- Mission Status is **inside** the ORCH head card — not a floating modal above the tree.  
- Node strings measured under **identity transform** (fix pan/zoom misalignment).  
- Fit prefers **width** (min ~50%) so invader glyphs stay readable.  
- Branch labels: `SA-N · Chat N · repo`. Hold copy: **ORCH HOLD** + question + “answer via orchestrator”.  
- Glyph: pixel invader from operator ref (block body, square eyes, marching legs when working).

### 1.4 Rails

| Rail | Content |
|------|---------|
| **Left · STATS** | KPIs, charts, history (titles use SA-N) |
| **Right · OPS** | Tabs = `SA-N`; mission panel: Identity, Role = sub-agent under ORCH, **Talk to: ORCH only** |

### 1.5 Bottom dock — **ORCH desk** (not full-bleed DMs)

| Rule | Detail |
|------|--------|
| **Width** | Max **`--orch-w`** = `min(360px, 90vw)` — **same as** LOOPLET FLEET · ORCHESTRATOR head. Centered. Never full screen width. |
| **Layout** | Sub-agent panels **stack vertically** inside that width; scroll if many. |
| **Framing** | Header: `ORCH → SUB-AGENT` · `SA-N · Chat N · repo` · Topic |
| **Questions** | `ORCH asks · on behalf of SA-N` · Reply: **Reply ORCH** |
| **Toggle** | Show/Hide **ORCH desk** |
| **Brand sub** | `ORCH desk — questions on behalf of sub-agents` |

### 1.6 Interaction polish

- Board/CLAW: `user-select: none` so pan/click does not paint a giant text selection.  
- Inputs still selectable.  
- Copy in handover modal uses `user-select: text` on note bodies.

---

## 2. Handover notes (operator folders)

### Flow

1. Session **complete** or **stale wipe** → create handover JSON (`SA-N`, Chat, time, text).  
2. **Auto-deliver**: append to outbox + mark `delivered` + SSE toast/folder count.  
3. If deliver fails → stays `pending`; next **boot / SYNC / preflight** flushes again.  
4. Complete also **schedules board wipe** (~8s) so the lane leaves the screen.

### Storage

| Path | Role |
|------|------|
| `%USERPROFILE%\.claude\scratch\autopro-theater\handovers\*.json` | Notes |
| `%USERPROFILE%\.claude\scratch\autopro-theater\handover-outbox.md` | Operator inbox (auto-append) |

### API

| Method | Path | Use |
|--------|------|-----|
| GET | `/api/handovers` | List + pending count + outbox path |
| POST | `/api/handovers` | Create (`deliver` default true) |
| POST | `/api/handovers/flush` | Deliver all pending → outbox |
| GET/POST | `/api/preflight` | Stale/complete wipe + flush undelivered |

### SSE events (extra)

`handovers`, `handover`, `wiped` (plus existing `sessions`, `mission`, `needs_input`, `stall`, `complete`).

---

## 3. Production boot / kill loop

### Arm (`launch-showtime.ps1`)

1. Arm flag + worktree (unless `-NoWorktree`).  
2. **Ensure** theater server.  
3. **Stale process scan** — old runners for that root (e.g. &gt;2h) culled.  
4. **`POST /api/preflight`** — wipe complete/dead-pid stale lanes (handover first) + flush pending notes.  
5. **Register** new session (clean board, then new lane).  
6. Detach runner · open Board (extension handoff file or browser).

### Stop (`stop-autopro.ps1`)

1. Remove `autopro-on`.  
2. Kill runners (+ orphan `claude -p work` unless `-KeepClaude`).  
3. **`POST /api/preflight`** with `staleAfterMs: 0` — handover + **wipe dead lanes off the board**.

### Complete (runner)

1. Final check slice.  
2. Heartbeat `status: complete` → server writes/delivers handover → wipe timer.  
3. Merge + prune worktree.

---

## 4. Identity fields (API enrich)

Every session (after enrich) includes:

| Field | Example |
|-------|---------|
| `lane` | `2` |
| `chatLabel` | `Chat 2` |
| `subAgentNo` | `2` |
| `subAgentId` | `SA-2` |
| `agentRef` | `SA-2 · Chat 2` |
| `role` | `subagent` |

Home / extension KPIs can keep using `lane` / `needsInput`; Board UI prefers **SA-N** labels.

---

## 5. API contract (Board + Home)

**Base:** `http://127.0.0.1:8770` · `Cache-Control: no-store`

| Method | Path | Use |
|--------|------|-----|
| GET | `/api/health` | Ready |
| GET | `/api/sessions` | `{ sessions, mission }` |
| GET | `/api/mission` | Rollup |
| GET | `/api/events` | SSE |
| POST | `/api/sessions` | Register |
| POST | `/api/sessions/:id/heartbeat` | Progress / complete / stall |
| POST | `/api/sessions/:id/notes` | Note |
| POST | `/api/sessions/:id/questions` | Ask / answer |
| POST | `/api/sessions/:id/steers` | Steer |
| DELETE / POST | `/api/sessions/:id/unregister` | Wipe lane |
| GET/POST | `/api/handovers` · `/flush` · `/api/preflight` | Handover lifecycle |
| GET | `/` | Full UI |

---

## 6. Extension (still iframe-first)

| Surface | Ship |
|---------|------|
| **Home** | Health + fleet KPIs + Open Board + needs-you badge |
| **Board** | iframe `http://127.0.0.1:8770/?embed=1` |
| **Arm handoff** | `%USERPROFILE%\.claude\scratch\showtime-open.json` |

Do **not** rebuild CLAW/MAP/ORCH desk in React for v1.  
Permissions: `http://127.0.0.1:8770/*` · CSP `frame-src` for that origin.  
Details that remain valid for packaging: `references/HANDOVER-EXTENSION-BOARD.md` §5–§ arm handoff (UI inventory there is **superseded** by this doc).

---

## 7. Operator commands

```powershell
# Arm (preflight + register + runner + board)
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\autopro\scripts\launch-showtime.ps1" `
  -Root '<YOUR-REPO-ROOT>' -RepoDir '<YOUR-REPO-ROOT>'

# Hard stop (flag + kill + wipe board)
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\autopro\scripts\stop-autopro.ps1" `
  -Root '<YOUR-REPO-ROOT>'

# Soft stop only (wait mid-slice)
Remove-Item -LiteralPath '<YOUR-REPO-ROOT>\.claude\scratch\autopro-on' -Force -ErrorAction SilentlyContinue

# Manual server
node "$env:USERPROFILE\.claude\skills\autopro\scripts\theater-server.mjs"
```

**Board:** http://127.0.0.1:8770/  
**Outbox:** `%USERPROFILE%\.claude\scratch\autopro-theater\handover-outbox.md`

---

## 8. Files that define “latest UI”

| File | Owns |
|------|------|
| `theater/index.html` | Full board UI (ORCH/SA, CLAW, dock width, handovers modal, invader, pan/zoom) |
| `scripts/theater-server.mjs` | Sessions, enrich SA-*, handovers, preflight, complete wipe |
| `scripts/launch-showtime.ps1` | Arm + preflight |
| `scripts/stop-autopro.ps1` | Kill + board wipe |
| `scripts/autopro-runner.ps1` | Slice loop + complete |
| `scripts/theater-register.ps1` | Register / heartbeat / ensure |
| `references/SHOWTIME.md` | Short operator controls (update alongside this) |
| `references/HANDOVER-EXTENSION-BOARD.md` | Extension packaging (iframe) |

---

## 9. Acceptance checklist (UI)

- [ ] CLAW: Mission Status **inside** ORCH head; no detached fleet float over the tree  
- [ ] CLAW: Node strings land on branch tops under pan/zoom  
- [ ] Glyphs: coral **pixel invader** (not soft blob crab)  
- [ ] Labels: **SA-N · Chat N** everywhere operator-facing  
- [ ] Banner / dock: **ORCH asks on behalf of** SA-N; Reply ORCH  
- [ ] Dock width ≤ ORCH head (`--orch-w`); not full screen  
- [ ] One **HANDOVERS** folder → modal; Copy + Copy all  
- [ ] Complete/stale → note in outbox + folder; lane wipes  
- [ ] Arm/stop preflight clears stale lanes before/after  
- [ ] Click-drag board does not select a wall of text  

---

## 10. What changed vs earlier handovers

| Old | Now |
|-----|-----|
| Sticky mission bar always above Pac for all modes | MAP = per-lane; CLAW = in ORCH head; LIST = fleet strip |
| CLAW scroll-only | CLAW pan/zoom + Fit + node strings |
| Soft orange claw SVG | Pixel invader (`#e07a5f`) |
| “Chat N” only | **SA-N ≡ Chat N**; talk to ORCH only |
| Full-width multi-column dock | Narrow ORCH desk (`--orch-w`) stacked |
| Dock as direct chats | ORCH desk on behalf of sub-agents |
| No operator handover folders | Single folder + modal + outbox + preflight flush |
| Complete left lane forever | Handover + timed wipe |

---

*Canonical UI handover for Show Time as of 2026-07-10. Prefer this over older “sticky mission / Chat N dock” wording in extension notes.*
