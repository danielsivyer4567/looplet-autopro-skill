# Ledger: Show Time board — operator-annotation upgrades

Approved: yes @ 2026-07-12 (Phases A–C, SC-01→10). Phase D (SC-11→12) stays GATED — needs a separate explicit go.
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

## SC-01 — Repo NAME in header + OPS, not session-derived branch  [pending]
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
Commit: —

## SC-02 — Branch before session id on SA cards + OPS Repo row  [pending]
DONE (machine): a session with branch="feat/x", sessionId="sess_abc" renders
  "feat/x · sess_abc" (branch first), NOT "showtime/sess_abc · sess_abc".
DONE (human): SA card + OPS Repo row read branch-first; session id is the tail.
Files: theater/index.html (card title ~1363, OPS Repo row).
Notes: ②. s.branch exists. If branch is literally "showtime/sess_..", show the
  real git branch if register passes one; else label it clearly as the
  worktree ref, not a fake branch.
Commit: —

## SC-03 — Worker % = share of whole ledger (consistent everywhere)  [pending]
DONE (machine): the % shown next to the active slice on the card equals the %
  shown on the orbiting bug for the SAME session (single source: done/total of
  that session's ledger). Unit: a tiny pure fn pctOfLedger(session) used by
  both render sites; add a self-test comment block or console.assert dev-gate.
DONE (human): the 3% vs 12% mismatch is gone — one number, meaning "share of
  the whole lot".
Files: theater/index.html (slice line ~1372, bug pct render).
Notes: ③. Define ONE pct source and reuse. Pure calc.
Commit: —

---

# Phase B — Animation (legs, clockwise orbit, stagnant-still)

## SC-04 — Active worker bug orbits its slice clockwise + legs moving  [pending]
DONE (machine): CSS-only; an .orbit keyframe path exists; a session with
  status running/in-progress adds an "orbiting" class to its bug; node --check
  n/a (CSS/HTML); no JS error.
DONE (human): the active worker's crab visibly travels CLOCKWISE around the
  perimeter of its working slice, legs animating (matches the green loop the
  operator drew). ④ + ⑬.
Files: theater/index.html (CSS @keyframes + .claw-icon.orbiting; render adds
  the class when st==='running'||slice.state==='in-progress').
Notes: reuse inv-leg-l/r for legs; add an orbit path animation. Perf: transform
  only, one element. Pause when tab hidden (prefers-reduced-motion respected).
Commit: —

## SC-05 — Stagnant = frozen legs + reads as BAD (red)  [pending]
DONE (machine): a session status stalled/stagnant → bug has NO leg animation
  and gets a .bad/.stagnant class; card border/badge turns rose; no JS error.
DONE (human): a stagnant SA is obviously "no good" — still legs, red highlight,
  distinct from a calm idle. ⑤ + ⑪ + ⑫.
Files: theater/index.html (CSS .stagnant already exists ~257; extend to card +
  bug; render gates leg anim off on stalled/stagnant).
Notes: don't animate legs on stalled. Red = warning, reserve for genuinely
  stuck (stalled/blocked), not merely queued.
Commit: —

---

# Phase C — States & ORCH attention (surface existing data)

## SC-06 — Slice state labels: pending / standby(+reason)  [pending]
DONE (machine): a slice with state 'pending' shows "pending" (next in line);
  a slice with a standbyReason shows "standby — <reason>"; missing reason on a
  standby renders "standby — (no reason given)" so it's never silently blank.
DONE (human): pending vs standby are visually distinct; standby always shows
  WHY (e.g. "conflicting paths"). ⑥.
Files: theater/index.html (slice line render ~1372-1380); server may pass a
  standbyReason field through registerSession if present (optional, additive).
Notes: pending already derivable; standby+reason is the new label. If the
  server has no reason yet, show the placeholder — do NOT fake a reason.
Commit: —

## SC-07 — ORCH previous-notes log + click-to-open  [pending]
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

## SC-10 — Verify + doc: board upgrade pass  [pending]
DONE (machine): board loads, SYNC works, token self-heal intact, no console
  errors across LIST/MAP/CLAW; a short note appended to OPERATOR-HANDOVER.md
  §4 describing the new signals.
DONE (human): operator eyeballs all of SC-01..08 on the live board.
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

## SC-11 — Conflict detection: two SAs touching the same paths  [pending]
DONE (machine): server computes overlap between sessions' changed-file sets (or
  worktree branch bases) and marks a conflict flag; unit test on the overlap fn.
DONE (human): "conflicting chats / working over each other" surfaces truthfully.
Files: scripts/theater-server.mjs (+ data from register/runner), index.html badge.
Notes: ⑦. Needs a real signal (git diff --name-only per worktree, or slice path
  claims). Design first. GATED.
Commit: —

## SC-12 — Drift resolution + "waiting on user decision" clarity  [pending]
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
· SC-10 verify. Phase D (SC-11→12) only after an explicit second go — it's
detection logic, not display.

## Autopro notes
- One slice per fresh `work` session; commit only that slice's files.
- Pure display/animation slices are low-risk; keep them CSS/render-local.
- Never fake a state the server can't back (standby reason, conflict) — show a
  clear placeholder instead.
- Board must still SYNC + self-heal token after every slice.
