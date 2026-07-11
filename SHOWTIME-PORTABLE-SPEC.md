# Show Time — Portable Multi-Repo Board Spec

**Purpose of this document.** Hand this (plus `SHOWTIME-PORTABLE-SPEC.svg`) to
any model in any repo so it can build its OWN Show Time board that other repos
join. This is the complete, self-contained explanation — architecture, the
join contract, the visual language, and the two hard-won rules (the *beacon*
and *find-or-attach*) that stop it from breaking. Nothing here assumes the
autopro skill; re-implement it anywhere.

> The reference implementation lives in the autopro skill:
> `scripts/theater-server.mjs` (server), `theater/index.html` (board UI).
> Read those if you want working code. This doc is the portable contract.

---

## 0. The one-sentence idea

> **One localhost board process. Any repo joins its canvas as a numbered lane.
> Nobody is handed a URL — a small set of files (the *beacon*) is the
> rendezvous, and every joiner *finds-or-attaches* to the running board instead
> of spawning a rival.**

The operator watches one canvas. Each repo/agent is a lane (SA-1, SA-2, …).
The operator talks only to the host (ORCH); the lanes report up.

---

## 1. THE BEACON — how joiners find the board WITHOUT a URL

A URL is the wrong rendezvous: the port can change, it has to be copied by
hand, and the surface people actually watch (a browser extension panel) has no
address bar at all. So the host does not advertise a URL. It writes **files**.

On boot, the host writes to a well-known directory:

```
<home>/.claude/scratch/autopro-theater/
  server.port    →  "8770"            which TCP port the board is on
  server.token   →  "<48 hex chars>"  per-boot auth token (see §5)
  server.pid     →  "<pid>"           liveness / stale detection
```

**Any process on the machine** (a joiner script, a browser extension via its
companion, a second repo's runner) discovers the board by reading `server.port`
— not by knowing a URL. That is the "signal being put off" that a joiner
listens for.

**Do NOT** try to detect the board by sniffing for "a Chrome window with a
blank URL" or scanning windows. It is unreliable and fragile. The beacon files
are deterministic — use them. (The blank-URL extension surface is real and
good; it just reads the beacon like everything else, it does not get detected.)

---

## 2. FIND-OR-ATTACH — reuse the board, never spawn a rival

This is the rule that prevents the single worst failure mode (two boards, two
runners racing one ledger). **Before** starting a server OR opening the board,
every joiner runs this:

```
port  = read(server.port) or default 8770
alive = GET http://127.0.0.1:{port}/api/health  → 200 && body.ok

if alive:
    ATTACH  → POST /api/sessions to register as the next lane.
              DO NOT start a second server.
else:
    SPAWN   → start ONE server, write the beacon, then register.
```

**The bug this kills.** A naive server, on `EADDRINUSE` for :8770, port-scans
to 8771 and starts a *rival* board — and a second runner ends up racing the
same ledger. Find-or-attach makes the board a **singleton**: an existing board
on :8770 causes new arms to *attach*, not clone. The server itself must also
check: on `EADDRINUSE`, probe :8770/api/health — if it's *our* board, exit and
let the caller attach; only port-scan if some *other* app holds the port.

**For a browser extension / embedded panel:** same rule. Read the port from the
beacon (via a companion process that can read the file), probe health, render
the board inline. Never hard-code :8770 as the only option — that breaks the
moment the board lands elsewhere.

**Tailscale note.** The server binds `127.0.0.1` only. A same-machine
viewer (extension, local tab) reaches it via loopback — Tailscale is not in
that path and makes no difference. Tailscale only matters to let *another
device* on the tailnet reach the board: put `tailscale serve` in front; the
server still binds loopback and nothing about the local contract changes.

---

## 3. MULTI-REPO JOIN — one canvas, N repos as lanes

- **Host repo** runs the server, writes the beacon, and IS the ORCHESTRATOR
  node on the canvas.
- **Each joining repo** POSTs `/api/sessions` with its own `repoId`, `repoPath`,
  `branch`, and ledger info. The server assigns it the next free lane
  (`nextLane()` — SA-1, SA-2, … never colliding) and it appears as its own lane.
- **6 people = 6 lanes, zero URLs shared.** Each ran find-or-attach → all joined
  the same board. The operator addresses only ORCH; lanes heartbeat upward.

A lane's ledger slices (SC-01, SC-02, …) become the small **slice rows** shown
under that lane. That is the unit the worker-orbit animates around (§4).

---

## 4. THE VISUAL LANGUAGE (this is exact — get it right)

### Worker orbit — the "it's alive" signal
Each **in-progress slice row** (the little "SC-17 · title · working" box) has
its own worker crab. **That crab walks the perimeter of ITS OWN slice row** —
a small loop around that one task box, like a clock hand sweeping that little
cell's edge, legs marching as it goes.

- It orbits the **individual slice row**, NOT the whole lane card, NOT the ORCH.
- One orbiting crab **per in-progress slice** (several can orbit at once).
- `pending` / `done` slice rows do **not** orbit — legs still.

CSS mechanism (reference):
```css
.claw-node { position: relative; }          /* the slice row = the orbit box */
.claw-node.in-progress .crab {
  position: absolute;
  animation: orbit 3s linear infinite;       /* TL → TR → BR → BL → TL */
}
@keyframes orbit {
  0%{left:2px;top:2px} 25%{left:calc(100% - 24px);top:2px}
  50%{left:calc(100% - 24px);top:calc(100% - 24px)}
  75%{left:2px;top:calc(100% - 24px)} 100%{left:2px;top:2px}
}
/* legs march on an inner <g>; pause both on body.tab-hidden +
   prefers-reduced-motion: reduce */
```
It is `left/top` on one out-of-flow element (cheap, no sibling reflow), NOT
`transform %` (which is self-relative and can't trace a variable-size box).

### States
| State | Visual |
|---|---|
| **working** | crab orbits its row, legs march |
| **pending** | next in line — legs still, no orbit |
| **standby** | legs still + **must display a reason** (e.g. "conflicting paths"); never blank |
| **stalled / stagnant** | legs still + **RED** highlight = "no good"; ORCH must notice |
| **done** | ✓, quiet |

### ORCH attention
- **Escalation:** when a lane is stalled/blocked and can't be nudged, the ORCH
  node shows a pulsing **RED "CLICK HERE"** that jumps the operator to that lane.
- **Previous-notes log:** ORCH shows a Notes folder (with a count) → click opens
  a modal with the running update log. Data source: `session.notes[]`.

### Notifications
On **slice-done** OR **lane-complete**, fire a Web Notification + an optional
sound. Toggle: `off` / `per-task` / `per-line` (persist in localStorage).
Detection is a diff of prev→new `done` counts on the poll/SSE data — no server
change needed. Ask notification permission once, on first enable; respect mute.

---

## 5. THE JOIN CONTRACT (implement these and any repo can join)

All under `http://127.0.0.1:{port}`.

| Method / Path | Purpose | Auth |
|---|---|---|
| `GET /api/health` | `{ok, port, sessions}`. **The find-or-attach probe.** Returns `token` to a **same-origin** request only (so the board page can self-heal a stale token). | **PUBLIC** |
| `POST /api/sessions` | Register / join. Body below. Returns the assigned lane. | token |
| `GET /api/sessions` | The whole canvas: `[{lane, subAgentId:"SA-N", repoId, branch, status, slice, counts, notes}]` | token |
| `POST /api/sessions/:id` | Heartbeat / status / slice progress / `{unregister:true}` | token |
| `GET /api/events` | SSE stream — live push to the board page | token |
| `GET /api/mission` | Fleet rollup `{total, done, pct, remaining}` | token |

**Register/join body** (POST /api/sessions):
```json
{
  "sessionId":  "sess_ab12cd34",         // stable per session; server mints if absent
  "repoId":     "looplet-ai",            // SHORT repo NAME (basename of repoPath)
  "repoPath":   "C:/repos/looplet-ai",   // full path (derive repoId from this)
  "branch":     "feat/x",                // real git branch — shown BEFORE the sessId
  "ledgerPath": ".claude/scratch/ledger.md",
  "ledgerHash": "…", "ledgerTitle": "…",
  "status":     "running"                // running|stalled|blocked|needs_input|complete
}
```
The server assigns `lane`, `subAgentId:"SA-<lane>"`, `chatLabel:"Chat <lane>"`.
Display rule: show **repo NAME** (not the brand, not the sess-derived branch),
and render branch as `"<branch> · <sessId>"` (branch first).

**AUTH model.** Every `/api/*` except `/api/health` requires `X-Showtime-Token`
(header or `?t=`), matched against `server.token`. **No `Access-Control-Allow-
Origin` header is ever sent** → a cross-origin web page can neither read
responses nor pass the token check. The board page gets the token injected at
serve time. If the server restarts (new token) an open page self-heals: on a
401 it re-fetches `/api/health` (same-origin returns the fresh token) and
retries once — no OFFLINE, no manual reload.

---

## 6. Build order for a fresh host (checklist)

1. **Server**: bind `127.0.0.1:{port}`; on boot write `server.port/token/pid`.
   On `EADDRINUSE`, probe :8770/api/health — if it's our board, exit (attach);
   else port-scan. Implement the 6 endpoints in §5.
2. **Beacon reader / find-or-attach helper**: read `server.port`, probe health,
   return `{alive, port, url}` → attach or spawn. Every joiner uses it.
3. **Board page**: SSE from `/api/events`, render lanes from `/api/sessions`,
   token injected at serve + 401 self-heal, port from beacon (not hard-coded).
4. **Visual layer** (§4): slice-row worker orbit, states, ORCH escalation +
   notes log, notifications.
5. **Multi-repo**: a second repo runs find-or-attach → POST /api/sessions →
   appears as the next lane. Verify 3+ repos share one canvas, no rival server.

---

## 7. The non-negotiables (the mistakes this doc exists to prevent)

- **Beacon, not URL.** Discovery is file-based. Never require a human to type or
  copy an address; never sniff for a blank-URL window.
- **Find-or-attach, not spawn.** Probe health first. One board, singleton.
  Never port-scan to a rival on EADDRINUSE without checking it's not our board.
- **Orbit the slice ROW, not the card.** Per in-progress slice, small loop.
- **standby must show a reason. stalled must be RED. done must be quiet.**
- **Token gates everything but /api/health; no CORS header ever.** Same-origin
  health returns the token so the page self-heals.
