# Ultracode-pattern Autopro (design)

**Status:** P0–P2 implemented (2026-07-16)  
**Scripts:** `showtime-board-gate.ps1`, `launch-ultra.ps1`, `autopro-ultra.ps1`, `ultra-band-lib.ps1`, `test-ultra-p0-p2.ps1`  
**Goal:** Fan a ledger across parallel **band** workers (worktrees + queue) without multi-writing one checkout.

### P0–P2 shipped

| # | Feature |
|---|---------|
| **P0** | Board fail-closed: `Assert-BoardSessionRegistered` + OpenRegister must leave listable lane; `launch-showtime` refuses BOOT if gate fails |
| **P1** | Multi-engine band spawn via `worker-engines.ps1`; no `$PID` traps; Log never pollutes returns |
| **P2** | Stall kill after `StallMinutes` without git progress; exit without `band-result.json` → **failed** not done |

## Housing principle (non-negotiable)

**Show Time / ultra is structure + optics, not a model brand.**

| Layer | Owns |
|-------|------|
| **Housing** | Ledger, bands, worktrees, claims, queue labels (“starts after B01”), board fleets, concurrency C, merge-to-integration policy |
| **Worker** | Whatever the operator already uses: `claude` \| `codex` \| `gemini` \| `grok` (or `-Engine auto`) |

- If they call this from **Codex**, bands run **Codex**.
- If they pin **Grok** / **Gemini** / **Claude**, same structure, that binary.
- Board shows an **engine chip** per fleet/band — never imply “Claude-only.”
- Same adapter matrix as serial autopro: `worker-engines.ps1`.

**Does NOT replace:** ledger format, Show Time (still projector-only), vault/security iron laws.  
**Does replace (opt-in mode):** single-writer serial loop when ultra is armed.

---

## 1. Problem

Today:

```
ledger (50 SC) → 1 runner → 1 claude -p work → verifier → next SC
```

Wall clock ≈ (work + verify) × N. OTIS full-50 ≈ 12–20+ hours.

Ultracode:

```
task → JS workflow script → pipeline(items) → ≤16 concurrent agents → verify phases → one result
```

We want that **shape** with autopro’s durable ledger + multi-engine + Show Time.

---

## 2. Mental model (1:1 with Ultracode)

| Ultracode | Autopro-Ultracode |
|-----------|-------------------|
| Session stays free | Operator chat / Show Time board |
| Workflow **script** owns the plan | **Orchestrator** process (`autopro-ultra.ps1`) owns the plan |
| Script variables | `bands.json` + ledger claims on disk |
| `agent(prompt)` | Spawn engine worker in **isolated worktree** |
| `pipeline(items, fn)` | Fan-out over **bands** (SC ranges) with concurrency cap |
| Subagent context | Fresh `claude/codex/… -p` with band-scoped prompt |
| In-workflow verify | Per-band verifier (optional per-SC inside band) |
| ≤16 concurrent | `-MaxConcurrency` default **4–5** (machine + cost) |
| Isolated copies for file edits | **git worktree per band** (required) |
| `/workflows` UI | Show Time: one fleet, **SA-1…SA-N** = bands |
| acceptEdits | Existing `-AllowDangerousSkipPermissions` risk pair |

---

## 3. Core objects

### 3.1 One ledger (source of truth)

Unchanged path: `.claude/scratch/ledger.md`

- Still the only place SC status lives: `[pending]|[in-progress]|[done]|[blocked]`
- **Never compress / never hide** policy stays
- New optional front-matter:

```markdown
Parallel: yes
BandSize: 5
MaxConcurrency: 5
Mode: ultracode
```

### 3.2 Band

A band is a contiguous or policy-grouped list of SC ids:

```json
{
  "bandId": "B03",
  "sc": ["SC-11", "SC-12", "SC-13", "SC-14", "SC-15"],
  "worktree": "C:\\LOOPLET\\ai-sidebar\\extension\\.worktrees-ultra\\B03",
  "branch": "ultra/otis-B03",
  "sessionId": "sess_…",
  "state": "running|done|blocked|queued",
  "ownerPid": 12345
}
```

Default banding: `BandSize=5` → SC-01..05, 06..10, …  
Smarter banding (v2): group by **file affinity** from ledger `Files:` lines (minimize overlap).

### 3.3 Claim lock (ledger mutex)

To avoid two bands “taking” the same SC:

```
.claude/scratch/ultra-claims.json
{
  "SC-06": { "bandId": "B02", "at": "ISO", "state": "claimed" },
  ...
}
```

Orchestrator claims **atomically** (write temp + rename) before spawn.  
Worker may only flip ledger lines for **its claimed** SCs.

### 3.4 Worktree isolation (non-negotiable)

```
repo/
  .worktrees-ultra/
    B01/   # branch ultra/<ledgerHash>-B01
    B02/
    ...
```

- Created from **same base commit** at orchestrator arm time (or current HEAD if clean).
- Worker commits **only on its branch**.
- Orchestrator **never** lets two bands share a worktree.
- Merge phase is explicit (see §6) — not silent.

**Why worktrees:** Ultracode’s “isolated copy per file” equivalent for a multi-file SC band.

### 3.5 Show Time mapping

| Board | Meaning |
|-------|---------|
| ORCH head | Orchestrator session (human contact) |
| SA-k / Chat k | Band Bk worker |
| Active SC stack | That band’s SC list (not the whole 50 on every lane) |
| Legs moving | Band worker pid alive |
| Full green ring | Band complete (all its SCs done) |

Register **one join per band** with OpenRegister when risk flags set (AFK).

---

## 4. Process architecture

```
                    ┌──────────────────────────┐
  launch-ultra.ps1  │  ORCHESTRATOR (pwsh)     │
  -Mode ultracode   │  autopro-ultra.ps1       │
                    │  - parse ledger          │
                    │  - build bands           │
                    │  - claim SCs             │
                    │  - ensure worktrees      │
                    │  - pipeline spawn        │
                    │  - merge / final check   │
                    └────────────┬─────────────┘
           concurrency ≤ N       │
     ┌───────────┬───────────────┼───────────────┐
     ▼           ▼               ▼               ▼
  Worker B01  Worker B02     Worker B03      … (queued)
  worktree    worktree       worktree
  branch      branch         branch
  prompt:     prompt:        prompt:
  "work ONLY  "work ONLY     …
   SC in band"  SC in band"
     │           │
     ▼           ▼
  for SC in band (serial inside band*):
    mark in-progress → implement → gate → commit → mark done
  (*optional: serial SC inside band keeps band coherent;
    true SC-parallel inside band only if Files: disjoint)

     │
     ▼ after all bands terminal
  MERGE CONTROLLER
  - rebase/merge stack ultra/* → integration branch
  - conflict → block band, human or repair worker
  - final npm run gate on integration
  - FINAL_CHECK_STATUS
```

### 4.1 Two-level parallelism (like Ultracode phases)

| Level | Parallel? | Unit |
|-------|-----------|------|
| **Bands** | Yes (pipeline) | SC-01..05 vs SC-06..10 |
| **Inside band** | Default **serial** | SC-06 then SC-07… (safe) |
| **Verify** | Parallel with next band start? | Prefer **per-band verify after band** (not per-SC) to cut 2× cost |

**Speed win vs today:**

- Serial: `50 × (work+verify)`  
- Ultra bands of 5, concurrency 5, verify-per-band:  
  `~10 band-cycles × (5×work_serial + 1×verify)` wall ≈  
  `ceil(10/5) × …` ≈ **~2–4× wall reduction** if work dominates;  
  better if verify drops to once/band (**5–8×** possible).

### 4.2 Worker prompt contract (band agent)

```
You are an AutoPro BAND worker (engine=…).
Ledger: <path> (read/write ONLY your claimed SC lines).
Band: B0k — SC-aa … SC-zz (claimed).
Worktree: <cwd> (you are already here). Branch: ultra/…
Rules:
1. Process claimed SCs in order. Skip [done].
2. Do not touch other SC sections.
3. Prefer files listed in each SC Files: line. If you must edit a shared file
   (e.g. voice-service.js), take the ultra-file-lock for that path or skip and
   mark SC [blocked] with reason shared-file-contention.
4. npm run gate green before marking each SC [done].
5. Commit conventional messages with SC id.
6. When all claimed SCs done or blocked, write band-result.json and exit 0.
```

### 4.3 Shared-file lock (v1 simple)

```
.claude/scratch/ultra-file-locks.json
{ "shared/voice-file.js": { "bandId": "B01", "until": "ISO" } }
```

Orchestrator or worker acquires lock with TTL. Contention → SC blocked or re-queued to a **serialize tail** band.

**v2:** affinity banding so hot files land in one band only.

---

## 5. CLI / flags (proposed)

```powershell
# New entry (or extend launch-showtime.ps1)
pwsh -File launch-ultra.ps1 `
  -Root <repo> -RepoDir <repo> `
  -BandSize 5 `
  -MaxConcurrency 5 `
  -AllowDangerousSkipPermissions -IAcceptUnattendedRisk `
  -NoPerSliceVerifier `          # verify once per band (default ON for speed)
  -MergeMode stack `             # stack | octopus | none
  -BaseRef HEAD
```

| Flag | Default | Meaning |
|------|---------|---------|
| `-BandSize` | 5 | SCs per band |
| `-MaxConcurrency` | 4 | Live band workers |
| `-NoPerSliceVerifier` | true in ultra | Skip SC-level double Claude |
| `-BandVerifier` | true | One verify agent per band |
| `-MergeMode` | `stack` | How bands land on integration |
| `-KeepWorktrees` | false | Retain on success for debug |

Kill switch: delete `autopro-on.ultra` (orchestrator) **and** per-band `autopro-on.band-Bk`.

---

## 6. Merge strategy

### 6.1 Preferred: Graphite-like stack (or plain git rebase chain)

```
main (or arm base)
  └ ultra/otis-B01   (SC 1-5)
       └ ultra/otis-B02  (SC 6-10)
            └ …
```

Orchestrator merges B01 first → B02 rebase → …  
Conflict in B0k → mark band blocked, spawn **repair worker** on that worktree only.

### 6.2 Alternative: integration branch

```
git checkout -b ultra/integration <base>
foreach band in done-order:
  git merge --no-ff ultra/otis-Bk
```

Simpler; noisier history.

### 6.3 Final gate

On integration tree only:

```
npm run gate
FINAL_CHECK_STATUS=green|red
```

Do **not** claim epic done until this passes.

---

## 7. Show Time + AFK

- Orchestrator registers ORCH + N band lanes (OpenRegister).
- Heartbeat includes `bandId`, `scDoneInBand`, `concurrency`.
- AFK: same risk pair; no board Approve wait.
- **Single writer myth dies only because each writer has a worktree** — board can show many legs honestly.

---

## 8. Migration from mid-flight serial autopro

You **do not** need serial to finish.

1. `stop-autopro.ps1 -Root <repo>` (kills serial runner).
2. Leave already `[done]` SCs as done (e.g. SC-01..05).
3. Orchestrator builds bands **only from remaining pending**.
4. Worktrees from current HEAD (includes done commits) so bands start from latest code.
5. Arm ultra mode.

**Risk:** uncommitted dirty tree — orchestrator refuses unless `-Force` or stash.

---

## 9. Implementation phases (build order)

| Phase | Deliverable | Done when |
|-------|-------------|-----------|
| **P0** | This design + stop guidance | Doc landed |
| **P1** | `ultra-band.ps1`: parse ledger → bands.json | Unit-testable pure parse |
| **P2** | `ultra-worktree.ps1`: create/remove worktrees + branches | Isolated dirs exist |
| **P3** | `ultra-claim.ps1`: atomic claims + file locks | Two orchestrators can’t double-claim |
| **P4** | `autopro-ultra.ps1`: pipeline spawn band workers | N workers concurrent |
| **P5** | Band worker prompt + `band-result.json` | Band exits with statuses |
| **P6** | Merge controller + final gate | Integration green |
| **P7** | Show Time multi-lane register | Board shows SA per band |
| **P8** | `launch-ultra.ps1` + doctor checks | One-command AFK arm |
| **P9** | Affinity banding + serialize tail | Fewer shared-file blocks |

**Do not** implement P4 before P2 — parallel without worktrees is how repos die.

---

## 10. Cost / honesty

| | Serial autopro | Ultra autopro |
|--|----------------|---------------|
| Wall clock | Very high | Much lower |
| Token $ | High (N × work × verify) | Still high (N workers live) but less verify tax if per-band |
| Merge pain | None | Real — budget repair workers |
| Failure mode | One stuck SC stalls all | One band blocks; others finish |
| Safety | Proven single-writer | Needs claim+worktree discipline |

Ultracode is **expensive and fast**. Ultra-autopro same: set `-MaxConcurrency` for wallet/CPU.

---

## 11. Explicit non-goals (v1)

- Emulating Anthropic’s private workflow JS VM  
- Running parallel workers on **one** working tree  
- Auto-merge to `main` without final gate  
- Show Time growing git authority again  

---

## 12. Immediate operator actions (now)

```powershell
# Stop forever-serial (optional but recommended before cutover)
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\autopro\scripts\stop-autopro.ps1" `
  -Root "C:\LOOPLET\ai-sidebar\extension"

# After P8 exists:
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\autopro\scripts\launch-ultra.ps1" `
  -Root "C:\LOOPLET\ai-sidebar\extension" `
  -RepoDir "C:\LOOPLET\ai-sidebar\extension" `
  -BandSize 5 -MaxConcurrency 5 `
  -AllowDangerousSkipPermissions -IAcceptUnattendedRisk
```

Until P8 ships: manual equivalent = **5 worktrees + 5 launch-showtime** with **sliced ledgers** (band-only SC lists) — poor man’s ultra; orchestrator automates that.

---

## 13. Decision log

| Decision | Choice | Why |
|----------|--------|-----|
| Isolation | git worktree per band | Ultracode isolated copies; no shared-tree races |
| Inside-band SC order | Serial default | Shared module coherence |
| Verify | Per-band default | Biggest speed lever vs today’s double Claude |
| Merge | Explicit stack/integration | Never silent main |
| Claims | Disk JSON atomic | Multi-orchestrator safe |
| Show Time | Multi SA = bands | Honest legs without git authority |

---

*End design. Implement from P1 upward; cut over from serial only at P4+ with stop-autopro first.*
