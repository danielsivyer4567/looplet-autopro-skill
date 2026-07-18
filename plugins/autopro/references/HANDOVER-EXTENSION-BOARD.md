# Handover: Show Time → Looplet browser extension  
### Home (background) + Board page

**Date:** 2026-07-10 (UI inventory refreshed)  
**Audience:** Looplet / AI Sidebar MV3 extension engineers  
**Skill package:** `%USERPROFILE%\.claude\skills\autopro\`  
**Repo mirror:** `<loopletai>/.claude/skills/autopro/`  
**Live board (dev):** `http://127.0.0.1:8770/`  
**Canonical UI handover:** `references/HANDOVER-SHOWTIME-UI.md` ← **read this for current board chrome**  
**Skill / conventions:** follow `looplet-extension-core` (vault, SW ops, no secrets in Board URLs)

---

## TL;DR — what to implement

| Surface | What you ship |
|---------|----------------|
| **Home** (existing background home) | Compact **Show Time / fleet** strip: health, fleet KPIs, “Open Board”, open questions badge |
| **Board** (new nav page) | Full Show Time UI via **iframe** (recommended) of `http://127.0.0.1:8770/?embed=1` |
| **Arm handoff** | On panel open, pick up `%USERPROFILE%\.claude\scratch\showtime-open.json` and focus Board |

**Do not reimplement** MAP / LIST / CLAW / ORCH desk / handovers modal in React for v1 — host the theater.  
**Do not** put vault secrets in query strings or Board URLs.

---

## 1. Product shape (extension chrome)

```
Looplet extension (sidebar / full page)
├── Home              ← existing background home
│   └── Show Time strip (NEW)   fleet snapshot + Open Board
└── Board  ★          ← Show Time full surface (iframe theater)
    ├── 📁 HANDOVERS (single folder → modal · Copy / Copy all)
    ├── LIST / MAP / CLAW + SYNC + AUTO 2s
    ├── CLAW: ORCH head (mission inside) · SA-N branches · pixel invader
    ├── Left STATS · Right OPS (SA-N tabs · talk to ORCH only)
    └── Bottom ORCH desk (max width = ORCH head · not full-bleed)
```

### User flow

1. Operator arms **autopro / Show Time** (skill runner).  
2. Chat gets short **SHOWTIME TV** card with board URL once on-screen as a bare autolinked URL (wireframe only — not the live board).  
3. Launcher tries extension → else opens browser.  
4. Extension **Home** shows live fleet pulse; **Board** is the full operator surface.  

---

## 2. Home page work (background home)

Home is **not** a second MAP. It is a **gateway + pulse**.

### 2.1 UI block: “Show Time”

Place on Home (above or beside existing agents / CRM cards):

| Element | Spec |
|---------|------|
| Title | **SHOW TIME** · Looplet |
| Health | Green if `GET /api/health` 200 within 3s; else amber “Offline — arm autopro” |
| KPIs (fleet) | From `GET /api/sessions` or rollup: **chats**, **done**, **in-flight**, **needs you** |
| CTA primary | **Open Board** → navigate to Board tab / route |
| CTA secondary | **Retry** health (no-store fetch) |
| Needs-you | If any session `needsInput` or open questions → pulse badge; click → Board + focus that session if possible |

### 2.2 Data (Home only)

```http
GET http://127.0.0.1:8770/api/health
GET http://127.0.0.1:8770/api/sessions
```

- Poll every **5–10s** while Home is visible (lighter than Board’s 2s).  
- Use `cache: 'no-store'` + `?_=<timestamp>` on failure paths (same idea as Board SYNC).  
- If server down: show offline strip; **do not** crash Home.

Optional later: SSE `/api/events` on Home for `needs_input` only.

### 2.3 Out of scope on Home

- Pac canvas, CLAW tree, full mission float, steers, dock chats  
- Git / worktree / merge controls  

Those live on **Board** only.

---

## 3. Board page work

### 3.1 Iframe host (ship first)

```html
<iframe
  id="showtime-board"
  src="http://127.0.0.1:8770/?embed=1"
  title="Show Time Board"
  allow="autoplay"
  style="width:100%;height:100%;border:0;background:#0a0c10"
></iframe>
```

| Check | Behavior |
|-------|----------|
| Health OK | Mount iframe |
| Health fail | Empty state: “Start Show Time server / arm autopro” + Retry + link to docs |
| Deep link | `?sessionId=sess_…` optional (pass through to iframe if theater supports later) |

### 3.2 What the iframe already includes (do not rebuild)

Theater `theater/index.html` already has (see **HANDOVER-SHOWTIME-UI.md** for full detail):

| Feature | Behavior |
|---------|----------|
| **ORCH / SA-N model** | Operator talks to ORCH only; **SA-N ≡ Chat N** |
| **Mission Status** | MAP = per Pac card; CLAW = inside ORCH head; LIST = fleet strip |
| **LIST / MAP / CLAW** | Same bus; CLAW pan/zoom + node strings + pixel invader |
| **📁 HANDOVERS** | One folder → modal · Copy / Copy all · auto outbox |
| **SYNC / AUTO 2s** | Connection + cache bust; Shift+SYNC hard reload |
| **ORCH desk (dock)** | Max width = ORCH head (`--orch-w`); questions on behalf of SA-N |
| **Rails** | Stats + OPS (SA-N tabs) |

### 3.3 Embed polish (optional v1.1)

If `?embed=1`:

- Theater may later hide duplicate brand chrome; **not required** for first iframe ship.  
- Extension supplies outer nav (Home | Board); iframe is the stage.

---

## 4. Board API contract

**Server:** `scripts/theater-server.mjs` · default **`127.0.0.1:8770`**  
**Static:** `theater/` · **API** sends `Cache-Control: no-store`

| Method | Path | Use |
|--------|------|-----|
| GET | `/api/health` | Ready probe (Home + Board empty state) |
| GET | `/api/sessions` | `{ sessions, mission }` — fleet + per-chat |
| GET | `/api/events` | SSE: `sessions`, `mission`, `needs_input`, `stall`, `complete`, `handovers`, `handover`, `wiped` |
| POST | `/api/sessions` | Register (runner) |
| POST | `/api/sessions/:id/heartbeat` | Progress / stats / sentinel / complete |
| POST | `/api/sessions/:id/notes` | Operator note |
| POST | `/api/sessions/:id/questions` | Ask / answer |
| POST | `/api/sessions/:id/steers` | Steer next slice |
| GET/POST | `/api/handovers` · `/api/handovers/flush` · `/api/preflight` | Handover lifecycle + stale wipe |
| GET | `/` | Full Board UI |
| GET | `/assets/*` | Logos / TV art |

### Session fields you care about (Home KPIs)

From each session (enrich): `lane`, `chatLabel`, `subAgentId` (`SA-N`), `subAgentNo`, `agentRef`, `repoId`, `branch`, `status`, `counts`, `todo[]`, `needsInput`, `openQuestions`, `slice`, `stats`, `sentinel`.

---

## 5. Extension packaging / permissions

| Item | Requirement |
|------|-------------|
| Host permission | `http://127.0.0.1:8770/*` (and/or `http://localhost:8770/*`) |
| CSP `frame-src` | Allow `http://127.0.0.1:8770` |
| Nav | **Home** \| **Board** (distinct) |
| SW messages | Optional: `SHOWTIME_HEALTH`, `OPEN_BOARD`, `SHOWTIME_HANDOFF` |
| Vault / CDP | **Unchanged** — Board is not a secret surface |

Suggested message ops (names illustrative — match project conventions):

```js
// sidepanel / background
{ op: 'showtime.health' }           // → { ok, port, sessions }
{ op: 'showtime.openBoard' }        // focus Board route
{ op: 'showtime.handoff' }          // read showtime-open.json if fresh
```

---

## 6. Arm handoff (autopro → extension)

On arm, `showtime-open-board.ps1` **always** writes:

`%USERPROFILE%\.claude\scratch\showtime-open.json`

```json
{
  "op": "showtime-open",
  "mode": "extension|page",
  "boardUrl": "http://127.0.0.1:8770/",
  "sessionId": "sess_xxxxxxxxxxxx",
  "extensionId": "…",
  "at": "ISO-8601"
}
```

### Extension pickup (required for “open on arm”)

When Side Panel / Home opens (or SW on alarm):

1. Read handoff (companion file API, native messaging, or known path via companion).  
2. If `at` is **&lt; 2 minutes** old → navigate to **Board** and set iframe `src` to `boardUrl` (append `?embed=1` if missing).  
3. Mark handoff consumed (delete or set `consumed: true`).  

### Discovery order (launcher already does this)

1. `LOOPLET_EXTENSION_ID`  
2. `%USERPROFILE%\.claude\scratch\looplet-extension.json`  
3. Scan Chrome/Edge/Brave Extensions for name **Looplet**  
4. Companion `POST http://127.0.0.1:4321/showtime/open` (if you implement)  
5. Fallback: default browser → board URL  

**Pin unpacked ID:**

```json
// %USERPROFILE%\.claude\scratch\looplet-extension.json
{
  "extensionId": "abcdefghijklmnopqrstuvwxyzabcdef",
  "boardPath": "sidebar/sidebar.html"
}
```

Optional companion route:

```http
POST http://127.0.0.1:4321/showtime/open
Content-Type: application/json

{ "url": "http://127.0.0.1:8770/", "sessionId": "sess_…" }
```

→ Focus Board tab / open side panel on Board.

---

## 7. Chat vs Board (do not confuse)

| Surface | Role |
|---------|------|
| **Chat** | Short TV wireframe only (title + Board link + log hint). **Not** live Pac. Template: `theater/showtime-tv-card.md` |
| **Board** | Live operator theater (iframe) |
| **Home** | Pulse + gateway to Board |

---

## 8. Operator status log (local, not git)

Autopro also writes (repo scratch, gitignored):

`<repo>/.claude/scratch/SHOWTIME-STATUS.md`  
`<repo>/.claude/scratch/SHOWTIME-STATUS.events.jsonl`

Extension **does not need** to render this for v1. Optional Home “last status path” for power users.

---

## 9. Acceptance checklist

### Home

- [ ] Show Time strip visible on Home  
- [ ] Health green/red from `/api/health`  
- [ ] Fleet counts from `/api/sessions` (or “—” offline)  
- [ ] **Open Board** switches to Board route  
- [ ] Needs-you badge when any session needs input  
- [ ] Offline does not break rest of Home  

### Board

- [ ] Distinct nav item from Home  
- [ ] Iframe loads; health gate before mount  
- [ ] Sticky Mission Status stays top-center while Pac pans  
- [ ] LIST / MAP / CLAW switch works  
- [ ] SYNC / AUTO 2s present (inside iframe)  
- [ ] Dock notes/questions work  
- [ ] Offline empty state if server down  
- [ ] No secrets in Board URL  

### Handoff

- [ ] Fresh `showtime-open.json` opens Board on panel open  
- [ ] Stale handoff ignored  
- [ ] Works without extension (browser fallback — already skill-side)  

---

## 10. Suggested extension slices (order)

| # | Slice | Done when |
|---|--------|-----------|
| E1 | Host permission + CSP + health probe util | Health returns in SW/panel |
| E2 | **Board** route + iframe + offline empty | Board paints theater |
| E3 | Nav **Home \| Board** | Distinct tabs |
| E4 | **Home Show Time strip** | KPI + Open Board |
| E5 | Handoff read of `showtime-open.json` | Arm focuses Board |
| E6 | Optional companion `POST /showtime/open` | Instant panel focus |
| E7 | Home needs-you badge + deep focus | Click → Board |
| E8 | Settings: board base URL (default 8770) | Configurable later |

---

## 11. Key source files (skill)

| Path | Role |
|------|------|
| `theater/index.html` | Board UI (sticky mission, MAP/LIST/CLAW, SYNC) |
| `theater/assets/*` | Logos / TV art |
| `theater/showtime-tv-card.md` | Chat-only TV template |
| `scripts/theater-server.mjs` | API + static + SSE · port 8770 |
| `scripts/launch-showtime.ps1` | Arm + worktree + open |
| `scripts/showtime-open-board.ps1` | Extension discovery + handoff file |
| `scripts/autopro-runner.ps1` | Slice loop + status log + finish |
| `scripts/showtime-status.ps1` | Living `SHOWTIME-STATUS.md` (gitignored) |
| `scripts/showtime-worktree.ps1` | Isolation + merge + prune |
| `references/SHOWTIME.md` | Operator controls |
| `references/HANDOVER-EXTENSION-BOARD.md` | **This file** |
| `SKILL.md` | Operator contract |

---

## 12. Explicit non-goals (this handover)

- Replacing Mission Control CRM canvas  
- Running git merge from the extension  
- Rebuilding Pac/CLAW natively in React (v1)  
- Production multi-tenant hosted board (phase 2 → option C: hosted iframe URL)  

---

## 13. Bottom line for the extension agent

1. **Home** = pulse + **Open Board**.  
2. **Board** = iframe `http://127.0.0.1:8770/?embed=1`.  
3. **Handoff** = read `showtime-open.json` when fresh.  
4. Sticky Mission Status / Pac / LIST / CLAW / SYNC are **already in the theater** — host them; don’t rewrite for v1.  
5. Vault stays vault; Board stays localhost operator chrome.

**Verify theater live:** open `http://127.0.0.1:8770/` · Ctrl+F5 · confirm sticky Mission over Pac, LIST, CLAW, SYNC bar.

---

*End of handover. Questions: arm flow → skill `autopro`; extension vault/SW → `looplet-extension-core`.*
