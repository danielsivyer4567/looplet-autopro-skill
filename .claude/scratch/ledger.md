# Ledger: Show Time MAP (Pac-Man) honesty parity + shared-board soak
Approved: yes @ 2026-07-15 (user: approve)
Graph: n/a

> GOAL: Bring the **Pac-Man MAP view** up to the same honesty bar as CLAW, then
> prove the full loop: arm this skill repo → watch both MAP + CLAW → slices
> complete → commits land here → handover absorbs cleanly.
>
> CLAW is the control panel we already fixed (ORCH head, single-writer, legs,
> ledger projectors, purge-dead). MAP still paints every session as a Pac lane
> with little regard for owner/corpse/projector — fix that without breaking
> the shared multi-ledger board.
>
> WATCH PLAN (human):
>   - Board: http://127.0.0.1:8770/  (Ctrl+F5 after arm)
>   - Use **CLAW** as the live theater for fleet tree / legs / ORCH
>   - Flip to **MAP** to verify Pac lanes match the same truth
>
> HOUSE LOCKS:
>   - Show Time still does **zero git** (no push/merge) — worker commits in this repo
>   - One coding writer per repo root; other ledgers = projectors (visible, no legs)
>   - Join alarm once per new ledger only
>   - Arm from this skill root only (not ai-sidebar main)
>
> ROOT (arm here):
>   %USERPROFILE%\.agents\skills\autopro
>   (same tree as %USERPROFILE%\.claude\skills\autopro)
>
> GREEN BAR:
>   - node --check scripts/theater-server.mjs
>   - node scripts/test-worker-ownership.mjs
>   - node scripts/test-legs-honesty.mjs
>   - node scripts/test-fleet-group.mjs
>   - pwsh -File scripts/prove-approve-arm-offline.ps1 → READY_CHECK=green
>   - pwsh -File scripts/test-showtime.ps1 → failed=0
>
> Prior epic (housing READY): done — see SHOWTIME-HANDOVER.md + skill master 4f4f14d

## SC-01 — MAP honesty audit: document gaps vs CLAW  [done]
Read `theater/index.html` `renderLanes` + CLAW helpers (`sessionHasWorker`,
  `legsShouldRun`, `workerColumnPlacement`, `groupSessionsByFleet`).
Write a short gap list in Notes of this slice (or `references/MAP-VS-CLAW.md`
  one page max): what MAP ignores (isWorkerOwner, corpse, ledgerProjector,
  fleet-by-root headers).
DONE (machine): gap file or Notes block exists; no behavior change required
DONE (human): list matches what you see on MAP vs CLAW with the live session
Files: theater/index.html (read), optional references/MAP-VS-CLAW.md
Notes: Research only — do not redesign MAP in this slice
  2026-07-15: wrote references/MAP-VS-CLAW.md — MAP flat sessions.map ignores
  isWorkerOwner/corpse/ledgerProjector; no fleet headers; RUNNING from status only.
Commit: —

## SC-02 — Shared lane honesty helpers for MAP  [done]
Extract or reuse pure decisions so MAP and CLAW cannot disagree:
  - `laneHonesty(s)` → { kind: 'owner-coding'|'owner-idle'|'projector'|'corpse'|'unarmed', showPac: bool, showGhost: bool, label: string }
  Mirror server flags: isWorkerOwner, pidAlive, corpse, ledgerProjector
Wire MAP `renderLanes` to use it (minimal paint change).
DONE (machine): node test (extend test-legs-honesty or test-worker-ownership)
  asserts projector → no “coding pac” claim; corpse → dim/dead lane; owner+running → active pac
DONE (human): MAP meta line says LEDGER / DEAD / coding consistently with CLAW
Files: theater/index.html, scripts/test-*.mjs
Notes: Depends on SC-01 for naming only
  2026-07-15: scripts/lane-honesty.mjs + test-lane-honesty.mjs ALL OK;
  index.html laneHonesty + renderLanes meta CODING/LEDGER/DEAD/BOARD; RUNNING only if coding.
Commit: —

## SC-03 — MAP fleet grouping: one MAP section per repo root  [done]
Stop dumping all sessions as a flat anonymous list. Group by
  `groupSessionsByFleet` (already pure) — section headers:
  MAIN · producer / SIDE · extension style labels + repo basename.
Each group lists its SA Pac lanes (owner + projectors).
DONE (machine): offline test that 2 sessions same root + 1 other root → 2 MAP groups
DONE (human): MAP shows fleet headers; not one unsorted blob
Files: theater/index.html, scripts/test-fleet-group.mjs or new test-map-group.mjs
Notes: Visual only; no server change required if sessions already enriched
  2026-07-15: mapLaneHtml + groupSessionsByFleet sections (.map-fleet MAIN/SIDE);
  test-fleet-group.mjs SC-03 asserts + source scan ALL OK.
Commit: —

## SC-04 — MAP owner Pac vs projector lanes (no fake CLEAR/RUNNING)  [done]
Apply honesty to pac/ghost/meta:
  - owner + coding → pac marches on progress; RUNNING
  - projector → no running pac claim; badge LEDGER / projector; pellets ok from ledger %
  - corpse → collapsed or DEAD strip (optional short lane, no fake progress crawl)
  - unarmed board-only → stiff/start pac or ghost, not RUNNING coding
DONE (machine): unit assertions on laneHonesty kinds; test-showtime still exit 0
DONE (human): with live owner session, MAP pac looks “working”; projector lanes don’t look like twin writers
Files: theater/index.html, scripts/test-*.mjs
Notes: Pairs with SC-02 helpers
  2026-07-15: corpse-strip (no crawl); h-pac.calm no-chomp; RUNNING only if
  h.coding; projector LEDGER badge + calm pac + ledger pellets; unarmed BOARD.
  test-lane-honesty + test-showtime failed=0. prove-approve-arm still red on
  ai-sidebar pointer ledger (pre-existing; SC-06).
Commit: 4ad4c3d

## SC-05 — Nudge/steer/handover smoke on MAP-selected agent  [done]
Ensure selecting a MAP lane still targets ORCH desk steers/nudge for that sessionId.
Offline or live API: steer + consume + inbox line under a temp repoPath session.
DONE (machine): existing test-showtime nudge/steer pass; optional inbox assert remains green
DONE (human): from board, Nudge on the soak session leaves a note / listen state
Files: theater/index.html (wire only if broken), scripts/test-showtime.ps1
Notes: Do not invent cross-repo git push
  2026-07-15: MAP click setSelectedAgent(sessionId); selectedId wins over stale
  picker; .lane.sel + scroll ledge; CLAW branch same. test-map-select-nudge +
  showtime notes inbox + UI MAP→ORCH wire green.
Commit: 732d60d

## SC-06 — Prove offline suite still green after MAP edits  [done]
Run full bar: prove-approve-arm-offline + test-showtime.
Fix any regressions from SC-02..05.
DONE (machine): READY_CHECK=green; test-showtime failed=0
DONE (human): n/a
Files: scripts/*
Notes: Gate before arm soak
  2026-07-15: root cause of the pre-existing red (SC-04 note) = offline WhatIf
  self-test hardcoded -RepoDir C:\LOOPLET\ai-sidebar, whose ledger became a
  POINTER (not Approved: yes) → ledger_not_approved cascaded 4 fails. Fix stays
  in-repo (house lock: never touch ai-sidebar): test-arm-on-approve.ps1 +
  prove-approve-arm-offline.ps1 now build a throwaway Approved:yes fixture in
  TEMP and clean it up. Full bar green: node --check + worker-ownership +
  legs-honesty + fleet-group ALL OK; prove READY_CHECK=green assertions_failed=0;
  test-showtime failed=0.
Commit: 66fd810

## SC-07 — Arm soak: run this ledger under Show Time (CLAW watch)  [done]
**Only after SC-06 green and user keeps Approved: yes.**
Arm this skill root with launch-showtime (or board Approve).
Leave CLAW open as theater; flip MAP occasionally.
Complete remaining slices via runner (or document already done).
DONE (machine): autopro runner reaches ledger with only SC-07+ done or final check path
DONE (human): you watched CLAW while MAP stayed honest; no twin-writer panic
Files: live board; .claude/scratch/autopro.log
Notes: FIRST arm of this epic — feature branch preferred if dirty; skill is already on master
  2026-07-15: LIVE arm proven. Runner sess_dc06e995e926 armed 15:49:26 engine=claude
  branch=master board=http://127.0.0.1:8770/ (Show Time zero git). Runner reached this
  ledger with done=6 pending=2 → SC-07 first pending; this worker IS iter 2/10 spawned
  for SC-07 = machine criterion met. Green bar re-run under armed soak: node --check
  theater-server OK; test-worker-ownership ALL OK; test-legs-honesty ALL OK;
  test-fleet-group ALL OK; prove-approve-arm-offline READY_CHECK=green
  assertions_failed=0; test-showtime failed=0. Human CLAW/MAP watch = operator gate.
Commit: a2413cf

## SC-08 — Handover + skill pointer for MAP honesty  [pending]
Update SHOWTIME-HANDOVER.md + one line in SKILL.md: MAP uses same honesty as CLAW;
  projectors visible; zero git still true.
DONE (machine): docs exist; no contradiction with contract
DONE (human): cold agent can re-arm MAP soak from docs
Files: references/SHOWTIME-HANDOVER.md, SKILL.md
Notes: After SC-07 preferred
Commit: —

---

## Stop conditions

- [blocked] if MAP redesign would require a full rewrite — split further, don't freeze mid-render
- Never arm ai-sidebar main for this epic
- Never claim git push from Show Time
