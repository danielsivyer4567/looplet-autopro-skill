# Autopro + Show Time — Operator Handover

Everything you need to **see, stop, start, and reconnect** the autonomous
ledger runs and the Show Time board. Run all `pwsh` commands in a normal
PowerShell/Windows Terminal — you do NOT need the Claude Code IDE open.

Skill scripts live in: `C:\Users\danie\.claude\skills\autopro\scripts\`
State/flags live in each repo's: `.claude\scratch\`

---

## 0) Quick reference (the four you'll actually use)

```powershell
cd C:\Users\danie\.claude\skills\autopro\scripts

# SEE what's running (which ledgers, which sessions)
Get-ChildItem "C:\repos\looplet webb app" -Recurse -Filter "autopro-on*" -File -ErrorAction SilentlyContinue | Select FullName

# STOP EVERYTHING — see the WARNING below: -All misses repos not in its
# hardcoded root list. ALWAYS verify with the SEE command afterward, and
# clear any leftover flags per-repo.
pwsh -File stop-autopro.ps1 -All

# STOP ONE repo only
pwsh -File stop-autopro.ps1 -Root "C:\repos\looplet webb app\looplet crm"

# START a ledger run (needs an approved ledger.md in the repo first)
pwsh -File launch-showtime.ps1 -Root "<repo>" -RepoDir "<repo>"
```

---

## 1) See what's running

An autopro ledger is "armed" when a flag file exists at
`<repo>\.claude\scratch\autopro-on.<sessionId>` (or bare `autopro-on`).

```powershell
# List every armed ledger across the web-app repos:
Get-ChildItem "C:\repos\looplet webb app" -Recurse -Filter "autopro-on*" -File -ErrorAction SilentlyContinue |
  Select-Object FullName, LastWriteTime

# Watch a specific run's live log:
Get-Content "C:\repos\looplet webb app\looplet crm\.claude\scratch\autopro.log" -Wait
```

As of this handover, THREE ledgers were live:
- `looplet crm`                          → session a7ed83205ee9
- `looplet crm\Looplet`                  → session ef574243d064
- `looplet crm\looplet-self-repair-email-ui` → session 0d6ce275b39f

---

## 2) STOP a run — the important part

**Why "just delete autopro-on" felt broken:** the runner only checks the
flag *between* slices. An in-flight `claude -p work` slice keeps going until
it finishes. `stop-autopro.ps1` fixes this — it removes the flag AND kills
the in-flight claude child.

```powershell
cd C:\Users\danie\.claude\skills\autopro\scripts

# Stop ALL known repos (recommended when you want everything quiet):
pwsh -File stop-autopro.ps1 -All

# Stop ONE repo:
pwsh -File stop-autopro.ps1 -Root "C:\repos\looplet webb app\looplet crm"

# Stop but LEAVE the mid-slice claude running (let it finish its current slice):
pwsh -File stop-autopro.ps1 -All -KeepClaude
```

Flags of `stop-autopro.ps1`: `-Root <repo>` | `-All` | `-SessionId <id>` |
`-KeepClaude` (don't kill in-flight claude) | `-Quiet`.

### ⚠ WARNING: `-All` is NOT actually all
`-All` only stops repos in its hardcoded root list. On 2026-07-11 it killed
the runner but left FOUR armed flags (incl. `loopletai-otis`). Killing the
runner ≠ disarming — an armed flag lets it resume if re-triggered.

**Reliable full stop (do this every time):**
```powershell
cd C:\Users\danie\.claude\skills\autopro\scripts
pwsh -File stop-autopro.ps1 -All          # kills runners

# THEN find + clear every remaining flag, per-repo:
Get-ChildItem "C:\repos\looplet webb app" -Recurse -Filter "autopro-on*" -File -ErrorAction SilentlyContinue |
  ForEach-Object {
    $repo = (Split-Path (Split-Path (Split-Path $_.FullName)))  # .../.claude/scratch/flag -> repo
    pwsh -File stop-autopro.ps1 -Root $repo -Quiet
  }

# VERIFY nothing is armed (must print nothing):
Get-ChildItem "C:\repos\looplet webb app" -Recurse -Filter "autopro-on*" -File -ErrorAction SilentlyContinue | Select FullName
```
`theater-server.mjs` (the :8770 board) is SUPPOSED to keep running — ignore
it when checking for leftover processes; only `autopro-runner.ps1` and
`claude -p work` matter.

---

## 3) START a run

You need an **approved `ledger.md`** in the repo's `.claude\scratch\` first
(create with the `/ledger` skill, approve it, then arm). Then:

```powershell
cd C:\Users\danie\.claude\skills\autopro\scripts

# Arm + open the Show Time board:
pwsh -File launch-showtime.ps1 -Root "C:\repos\looplet webb app\looplet crm" -RepoDir "C:\repos\looplet webb app\looplet crm"

# Options:
#   -Engine auto|claude|codex|gemini|grok|ollama   (default auto)
#   -Model "<model>"   pin the model for slices
#   -VerifierEngine / -VerifierModel   optional separate reviewer
# Doctor (no arm):
#   pwsh -File …\autopro-doctor.ps1 -RepoDir <repo>
# Engines doc: references/ENGINES.md
#   -NoBrowser         arm without opening the board window
#   -NoWorktree        run in-place instead of a sibling worktree
#   -PushOnFinish      git push when the ledger completes
```

Or from a Claude chat: type `-autopro` after a ledger is approved (the skill
runs `launch-showtime.ps1` for you).

---

## 4) The Show Time board (http://127.0.0.1:8770/)

The board is served by `theater-server.mjs` on **:8770**. It's separate from
the companion (:4321) — different server, different token (`X-Showtime-Token`).

**Reconnect is now automatic** (fix committed 2026-07-11): the server mints a
fresh token each boot; the page now silently re-fetches it from `/api/health`
on a 401 and retries, so a server restart no longer strands the board as
OFFLINE. Two notes:
- A board window that was **open BEFORE this fix loaded** needs ONE hard
  reload (**Ctrl+Shift+R** or Shift-click SYNC) to pick up the new page code.
- After that, restarts self-heal — no OFFLINE, no manual reload.

**Reopen just the board** (without re-arming):
```powershell
pwsh -File C:\Users\danie\.claude\skills\autopro\scripts\showtime-open-board.ps1
# or just open http://127.0.0.1:8770/ in any browser tab
```

**Restart the board server** (to load the reconnect fix the first time):
```powershell
# find + stop the old :8770 server, then it re-launches on next arm,
# OR restart it explicitly:
Get-NetTCPConnection -LocalPort 8770 -State Listen -ErrorAction SilentlyContinue |
  ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }
# next launch-showtime.ps1 (or -autopro arm) starts the patched server.
```

---

## 5) Common situations

| I want to… | Do this |
|---|---|
| Stop all overnight runs | `pwsh -File stop-autopro.ps1 -All` |
| See if anything's still running | the `Get-ChildItem ... -Filter "autopro-on*"` command in §1 |
| Board says OFFLINE | Ctrl+Shift+R once (post-fix it won't recur) |
| Restart a ledger from scratch | stop-autopro first, then launch-showtime |
| Watch progress without the board | `Get-Content <repo>\.claude\scratch\autopro.log -Wait` |
| Let current slice finish, then stop | `stop-autopro.ps1 -All -KeepClaude` |

---

## 6) The reconnect-fix files (already applied, need server restart to load)
- `scripts/theater-server.mjs` — `/api/health` returns the current token to
  same-origin requests only (cross-site denied; CSRF value preserved).
- `theater/index.html` — fetch shim self-heals on 401 (refetch token + retry),
  and now matches full-URL `/api/` calls too (fetchLive was sending no token).
