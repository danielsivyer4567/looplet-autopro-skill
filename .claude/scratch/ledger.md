# Ledger: Show Time board — operator-annotation upgrades

Approved: yes @ 2026-07-12 (Phases A–C + find-or-attach, SC-01→11). Phase D (SC-12→13) stays GATED — needs a separate explicit go.
Graph: n/a
Created: 2026-07-12
Scope: The autopro Show Time board renders its OWN upgrades live (meta test).
Files live in: C:\Users\danie\.claude\skills\autopro\
  - theater\index.html         (board UI + CSS + render JS)
  - scripts\theater-server.mjs (session data, /api endpoints, token)
  - scripts\theater-register.ps1 (what session fields get registered)

## North star
The operator marked up the board with 13 asks. Most map to data that ALREADY
exists (branch, repoId/repoPath, notes[], status stalled/blocked/needs_input,
leg-animation + orch-sway keyframes). So this epic is mostly SURFACE existing
data correctly + ADD animations, NOT invent new tracking. Conflict/drift
DETECTION (real logic) is split out as the last phase, honestly scoped as
harder and gated.

## Already present (do not rebuild — verify + reuse)
| Exists | Where |
|---|---|
| session.branch, session.repoId, session.repoPath | server registerSession ~307; register.ps1 141-143 |
| session.notes[] array | server ~335 |
| status: stalled / blocked / needs_input / complete | server ~157-172 |
| leg keyframes inv-leg-l/r, orch-sway, .stagnant styles | index.html ~355-365, 250-265 |
| badge classes run/hold/bad/ok | index.html ~317-323 |
| OPS right rail (SA tabs, MISSION, IN-FLIGHT, LIVE STATUS, SENTINEL) | index.html (right panel) |
| mission % (m.pct), per-session done/total | index.html ~1156-1162, 1219 |

## Pass criteria (epic DoD)
1. A stalled/stagnant SA is unmistakable: red highlight + an ORCH-level
   CLICK-HERE attention control that opens its detail.
2. Repo NAME (not session-derived branch) is visible per session.
3. Branch displays as "<branch> · <sessId>" (branch first).
4. Active worker's bug orbits its slice clockwise with legs moving; stagnant
   bug has frozen legs and reads as bad.
5. Worker % is share of the WHOLE ledger, consistent between card and bug.
6. Slice states show pending / standby(+reason) clearly.
7. ORCH shows a previous-notes log with a click-to-open.
8. No console errors; board still SYNCs; token self-heal intact.

---

# Phase A — Display truth (repo, branch, %) — pure render, no server logic

## SC-01 — Repo NAME in header + OPS, not session-derived branch  [done]
DONE (machine): node --check theater-server.mjs clean; index.html loads with
  no console error; a session with repoPath="...\looplet-self-repair-email-ui"
  shows repo name "looplet-self-repair-email-ui" in the mission Scope line AND
  the OPS "Repo:" row.
DONE (human): header/OPS shows the real folder name, not just "Looplet" brand
  and not the sess_-derived branch.
Files: theater/index.html (mission render ~1219-1264, OPS repo row), maybe
  server enrich() to expose a clean repoName from repoPath basename.
Notes: repoPath already registered (register.ps1:142). Derive repoName =
  basename(repoPath). ①. Pure display.
Commit: 1f53dae

## SC-02 — Branch before session id on SA cards + OPS Repo row  [done]
DONE (machine): a session with branch="feat/x", sessionId="sess_abc" renders
  "feat/x · sess_abc" (branch first), NOT "showtime/sess_abc · sess_abc".
DONE (human): SA card + OPS Repo row read branch-first; session id is the tail.
Files: theater/index.html (card title ~1363, OPS Repo row).
Notes: ②. s.branch exists. If branch is literally "showtime/sess_..", show the
  real git branch if register passes one; else label it clearly as the
  worktree ref, not a fake branch.
  DONE: shared branchTag(s) → "<branch> · <sessId>" (branch leads, sess tail),
  used by SA card title + OPS. showtime/sess_* tagged "worktree ref". Repo name
  (SC-01) kept in its own OPS row.
Commit: 9e2edc9

## SC-03 — Worker % = share of whole ledger (consistent everywhere)  [done]
DONE (machine): the % shown next to the active slice on the card equals the %
  shown on the orbiting bug for the SAME session (single source: done/total of
  that session's ledger). Unit: a tiny pure fn pctOfLedger(session) used by
  both render sites; add a self-test comment block or console.assert dev-gate.
DONE (human): the 3% vs 12% mismatch is gone — one number, meaning "share of
  the whole lot".
Files: theater/index.html (slice line ~1372, bug pct render).
Notes: ③. Define ONE pct source and reuse. Pure calc.
  DONE: added pure pctOfLedger(s)->{done,total,pct} (denominator prefers whole
  ledger: todos.length -> slice.total -> counts-sum). Routed ALL 4 per-session
  render sites through it: LIST/Pac, DETAIL/OPS, MAP/claw-bug, list-detail. Was
  divergent (repro fixture: LIST 3% vs MAP 11%) -> now 3% everywhere. console.assert
  dev-gate (67%, 2/3). Inline JS parse clean; theater-server.mjs node --check OK.
Commit: 893de31

---

# Phase B — Animation (legs, clockwise orbit, stagnant-still)

## SC-04 — Active worker bug orbits its slice clockwise + legs moving  [done]
DONE (machine): CSS-only; an .orbit keyframe path exists; a session with
  status running/in-progress adds an "orbiting" class to its bug; node --check
  n/a (CSS/HTML); no JS error.
DONE (human): the active worker's crab visibly travels CLOCKWISE around the
  PERIMETER OF THE CARD like a clock hand sweeping the border — top edge →
  right edge → bottom edge → left edge → back — NOT a tiny in-place wobble.
  From across the room it must read as "walking the node's border", a big
  obvious loop, legs marching as it goes. Workers only (NOT the orchestrator).
  ④ + ⑬.
Files: theater/index.html (CSS @keyframes + .claw-icon.orbiting; render adds
  the class when st==='running'||slice.state==='in-progress').
Notes: reuse inv-leg-l/r for legs; add an orbit path animation.
  CORRECTION (operator, 2026-07-12): the first pass built a ±4px micro-orbit
  (translate 4px,0 → -4px,0) — that's an 8px jiggle in place, NOT the intended
  clock-hand sweep of the card's edge. REDO the geometry so the bug travels the
  actual card perimeter: position it absolute inside the card and animate
  top/left (or offset-path: a rounded-rect border path via CSS motion-path) so
  it visibly circles the whole node border. Amplitude = the card's size, not a
  few px. Keep it transform/offset-path only (GPU), one element, paused on
  tab-hidden + prefers-reduced-motion. Workers only.
  DONE (redo): the working bug now goes position:absolute inside its .claw-node
  (node made position:relative, min-height:44px) and animates left/top around
  the REAL node box via @keyframes claw-orbit: TL(2,2)→TR→BR→BL→TL, clockwise,
  3.4s linear. Amplitude = the card itself (freeze-frame proof at 0/25/50/75%
  shows the bug at each corner). Legs still march on the inner <g> (running
  class kept). Workers only (orchSvg untouched). Paused via
  body.tab-hidden + prefers-reduced-motion:reduce. NOTE: used left/top not
  transform% — transform% is self-relative so it can't trace a variable-size
  parent box; left/top on one out-of-flow element is cheap (no sibling reflow).
Commit: e6396db

## SC-05 — Stagnant = frozen legs + reads as BAD (red)  [done]
DONE (machine): a session status stalled/stagnant → bug has NO leg animation
  and gets a .bad/.stagnant class; card border/badge turns rose; no JS error.
DONE (human): a stagnant SA is obviously "no good" — still legs, red highlight,
  distinct from a calm idle. ⑤ + ⑪ + ⑫.
Files: theater/index.html (CSS .stagnant already exists ~257; extend to card +
  bug; render gates leg anim off on stalled/stagnant).
Notes: don't animate legs on stalled. Red = warning, reserve for genuinely
  stuck (stalled/blocked), not merely queued.
  DONE: bug legs + badge were already handled (clawSvg(false)→.still, badge.bad,
  sessionWorkState→'stagnant' for stalled/error). The GAP was the CLAW-MAP card:
  data-edge="stagnant" was emitted (render ~2083) but UNSTYLED, so only the badge
  went rose. Added .claw-branch[data-edge="stagnant"] .claw-branch-card → rose
  border + faint glow (whole node reads BAD, not just badge). Also folded
  .track.blocked into .track.stalled so blocked lanes read rose too (LIST view).
  No render/JS change — hooked existing attribute. Verified live on :8770:
  computed card border = rgba(251,113,133,.5), badge .bad, bug .still (frozen),
  0 console errors, playwright screenshot confirms red card. Pure CSS, GPU-safe.
Commit: 71d54b2

---

# Phase C — States & ORCH attention (surface existing data)

## SC-06 — Slice state labels: pending / standby(+reason)  [done]
DONE (machine): a slice with state 'pending' shows "pending" (next in line);
  a slice with a standbyReason shows "standby — <reason>"; missing reason on a
  standby renders "standby — (no reason given)" so it's never silently blank.
DONE (human): pending vs standby are visually distinct; standby always shows
  WHY (e.g. "conflicting paths"). ⑥.
Files: theater/index.html (slice line render ~1372-1380); server may pass a
  standbyReason field through registerSession if present (optional, additive).
Notes: pending already derivable; standby+reason is the new label. If the
  server has no reason yet, show the placeholder — do NOT fake a reason.
  DONE: added pure sliceStateLabel(t) (single source, sits beside pctOfLedger)
  + console.assert dev-gate — pending passes through; state 'standby' OR a
  standbyReason yields "standby — <reason>" and falls back to
  "standby — (no reason given)", never blank. Routed all 3 render sites through
  it: OPS/DETAIL todosHtml, CLAW node .ns line, LIST tags (new amber .tag.standby
  + title tooltip, distinct from blue pending). CLAW node cls: standby→hold(amber),
  NOT bad(rose) — rose stays SC-05-only. Server (additive): parseLedgerTodos now
  recognizes [standby] / [standby: <reason>] and carries standbyReason; deriveCounts
  gains a standby bucket; session total denominator now includes standby (remaining
  work). Verified live on isolated :8793 via playwright: CLAW shows "pending",
  "standby — conflicting paths", "standby — (no reason given)"; 0 console errors.
Commit: d805439

## SC-07 — ORCH previous-notes log + click-to-open  [in-progress]
DONE (machine): ORCH card shows a "Previous notes" affordance with a count;
  clicking opens the existing handover/notes modal populated from session
  notes[]; GET path returns notes; no JS error.
DONE (human): operator sees a running log of prior notes/updates on ORCH and
  can click to read them. ⑧.
Files: theater/index.html (ORCH card + reuse ho-modal ~805); server notes
  already in session (~335) — wire a notes list into the ORCH view.
Notes: reuse the existing handover folder modal machinery, don't build a new
  one. ⑧.
Commit: —

## SC-08 — Red CLICK-HERE escalation when an SA is stuck/can't-be-nudged  [pending]
DONE (machine): a session with status stalled/blocked (and no open question it
  could self-resolve) surfaces an ORCH-level red "CLICK HERE" control; clicking
  focuses that SA in the OPS rail / opens its detail. Uses EXISTING status —
  no new detection. Highlighted (pulse/red) per ⑨⑩.
DONE (human): when SA-1 is stuck and can't be nudged, ORCH shows an
  unmissable red CLICK-HERE that jumps the operator to the problem.
Files: theater/index.html (ORCH card alert region; reuse has-pending pulse
  style ~47).
Notes: ⑨ + ⑩. This surfaces existing stalled/blocked status — it is NOT the
  conflict-DETECTION work (that's Phase D). Keep them separate.
Commit: —

## SC-09 — Notifications + sound on task / line-of-tasks finished  [pending]
DONE (machine): when a slice transitions to done (or a whole SA lane clears),
  the board fires a notification: (a) a Web Notification if the user granted
  permission, and (b) an optional sound. A settings toggle persists in
  localStorage: off / on-each-task / on-line-complete, plus a sound on/off +
  volume. Detection is diff-based on the SSE/poll session data the board
  already receives (compare prev vs new done counts) — no server change needed.
  No console errors; sound file is a tiny embedded data-URI or bundled asset
  (no external fetch, CSP-safe).
DONE (human): a chime + toast fires when a task finishes (or when a lane of
  tasks completes, per the chosen mode); the operator can mute it or switch
  between per-task and per-line in a small settings control.
Files: theater/index.html (SSE/poll diff → notify(); settings UI in header or
  a gear; a short embedded beep or bundled sound in theater/assets/).
Notes: ⑭. Pure client-side. Ask permission on first enable, never nag. Respect
  a global mute. Per-task can be chatty on big ledgers → default to
  on-line-complete. Distinct sound for "line complete" vs single task is a nice
  touch if cheap.
Commit: —

## SC-10 — Find-or-attach: reuse an existing board, never spawn a rival  [pending]
DONE (machine): (1) theater-server.mjs: BEFORE the EADDRINUSE port-scan
  (~1122), probe :8770 /api/health — if a healthy Show Time board already
  answers there, DO NOT start a second server; log "attach: existing board on
  8770" and exit 0 (the caller reads server.port and uses it). Only fall
  through to the port-scan when the port is held by something that is NOT our
  board (health probe fails/!ok). (2) A pure helper find-board (a small
  function or scripts/find-board.ps1 / .mjs) that: reads the beacon
  server.port from ~/.claude/scratch/autopro-theater/, probes
  /api/health, and returns {alive, port, url} — "attach" if alive else
  "spawn". (3) launch-showtime.ps1 uses find-board so a second arm ATTACHES
  to the running board as the next lane instead of throwing or spawning.
  node --check theater-server.mjs clean; a unit/dev-probe shows: with a board
  up, a second ensure returns attach (same port), and does NOT open :8771.
DONE (human): starting a 2nd/3rd/6th session joins the SAME board (next lane),
  no new port, no rival server; joiners never need a URL — the beacon files
  are the rendezvous.
Files: scripts/theater-server.mjs (~1122 port bind), scripts/launch-showtime.ps1
  (reuse path ~90/112/154), optional scripts/find-board (new tiny helper).
Notes: This is the deterministic "find-or-attach" — beacon = server.port +
  server.token files (NOT a URL, NOT a Chrome-window sniff). Fixes the live
  bug where EADDRINUSE spawned a 2nd board on 8771 and a 2nd runner raced the
  ledger. Reuse-first, spawn-only-if-dead. Keep it a singleton.
Commit: —

## SC-11 — Verify + doc: board upgrade pass  [pending]
DONE (machine): board loads, SYNC works, token self-heal intact, no console
  errors across LIST/MAP/CLAW; find-or-attach verified (2nd arm attaches);
  a short note appended to OPERATOR-HANDOVER.md §4 describing the new signals.
DONE (human): operator eyeballs all of SC-01..10 on the live board.
Files: OPERATOR-HANDOVER.md, quick manual pass.
Commit: —

---

# Phase D — Conflict / drift DETECTION (scoped separately, GATED)

> Honesty gate: SC-01..09 SURFACE data that already exists. The items below
> require the server to actually DETECT that two sessions are working over each
> other (same files/paths) or have drifted. That is real logic, not display,
> and must not be faked with a badge that isn't backed by data. Left [pending]
> and NOT part of the display pass. Do NOT start these under the same arm
> without an explicit go.

## SC-12 — Conflict detection: two SAs touching the same paths  [gated]
DONE (machine): server computes overlap between sessions' changed-file sets (or
  worktree branch bases) and marks a conflict flag; unit test on the overlap fn.
DONE (human): "conflicting chats / working over each other" surfaces truthfully.
Files: scripts/theater-server.mjs (+ data from register/runner), index.html badge.
Notes: ⑦. Needs a real signal (git diff --name-only per worktree, or slice path
  claims). Design first. GATED.
Commit: —

## SC-13 — Drift resolution + "waiting on user decision" clarity  [gated]
DONE (machine): a session blocked specifically on a user decision is labeled
  distinctly from a stall; a resolution affordance is shown.
DONE (human): operator can tell "waiting on ME" vs "stuck", and act. ⑦.
Files: theater-server.mjs (status refinement), index.html.
Notes: partly backed by needs_input already; the "drift resolution" path is new.
  GATED.
Commit: —

---

# Execution order
Phase A (SC-01→03) · Phase B (SC-04→05) · Phase C (SC-06→09, incl. notifications)
· SC-10 find-or-attach · SC-11 verify. Phase D (SC-12→13) only after an explicit second go — it's
detection logic, not display.

## Autopro notes
- One slice per fresh `work` session; commit only that slice's files.
- Pure display/animation slices are low-risk; keep them CSS/render-local.
- Never fake a state the server can't back (standby reason, conflict) — show a
  clear placeholder instead.
- Board must still SYNC + self-heal token after every slice.
