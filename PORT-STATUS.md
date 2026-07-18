# AutoPro cross-OS port — status

Isolated working copy of the AutoPro skill. **The live skill at `~/.claude/skills/autopro/` was
NOT touched** — this whole port lives here so the in-action Show Time run keeps going untouched.
Promote to the live skill only after a real macOS/Linux smoke (see "Not yet proven").

## What was ported — the process-API layer (the actual OS blocker)

Every Windows-only process primitive now goes through one module: **`scripts/proc-crossos.ps1`**.
On Windows each function runs the **exact same** call as before (behaviour unchanged); on
macOS/Linux it runs a `ps`/`nohup`/`Stop-Process` equivalent. It branches on pwsh 7's `$IsWindows`.

| Helper | Windows (unchanged) | Unix |
|---|---|---|
| `Get-AutoproProcessList [-Names]` | `Get-CimInstance Win32_Process -Filter Name=…` | parse `ps -axww -o pid,ppid,comm,args` |
| `Get-AutoproProcessById -Id` | `Get-CimInstance Win32_Process -Filter ProcessId=…` | `ps -p <id>` |
| `Stop-ProcessTree -Id` | `taskkill /PID <id> /T /F` (+ `Stop-Process` fallback) | descendant walk, kill leaves-first via `Stop-Process` |
| `Start-DetachedProcess -CommandLine [-CurrentDirectory]` | `Invoke-CimMethod Win32_Process Create` | `nohup <cmd> & echo $!` under `/bin/sh` |

### Call sites converted (13, across 7 scripts)
- `stop-autopro.ps1` — runner enum, worker enum, per-worker parent lookup, pid-file kill, worker
  kill, both verify enums (6 CIM + 2 taskkill blocks → helpers)
- `autopro-runner.ps1` — worker-timeout tree-kill (`taskkill` → `Stop-ProcessTree`)
- `autopro-ultra.ps1` — band-stall child kill (`Get-CimInstance … ParentProcessId` → `Stop-ProcessTree`)
- `autopro-status.ps1` — `Get-Runners` enum
- `arm-on-approve.ps1` — `Get-LiveRunnerPids` enum
- `launch-showtime.ps1` — 4 runner enums + the runner detach (`Win32_Process.Create` → `Start-DetachedProcess`)
- `launch-ultra.ps1` — ultra orchestrator detach
- `theater-register.ps1` — Show Time server detach

Each script gains one line: `. (Join-Path $PSScriptRoot 'proc-crossos.ps1')`.

## Also ported — the path/env layer

The second layer (what used to fault on Unix even after the process layer worked):
- **`$env:USERPROFILE` → `($env:USERPROFILE ?? $HOME)`** everywhere in the core scripts. On Windows
  `USERPROFILE` is set → identical; on Unix it's `$null` → falls back to `$HOME`. (Verified on this
  box: `$HOME -eq $env:USERPROFILE`.)
- **Backslash path literals → forward slashes** (`'.claude\scratch\…'` → `'.claude/scratch/…'`).
  Forward slashes resolve in Windows file APIs (verified) and are the only separator on Unix.
  Applied by an auditable exact-fragment codemod (per-file counts logged); BOM/EOL preserved;
  confirmed no regex-literal collisions first. Residual functional backslash-paths: **0**.
- **`worker-engines.ps1`** — each resolver (node/claude/grok/ollama/codex-js) now takes a Unix
  early-return (PATH lookup via `Get-Command`) so the Windows exe-search path is byte-identical and
  the null-`Join-Path` (Windows env roots are `$null` on Unix) never runs on Unix. `npm root -g`
  result is directory-validated before use.

Files in this layer: launch-showtime, autopro-runner, theater-register, autopro-status,
stop-autopro, launch-ultra, autopro-ultra, showtime-status, showtime-board-gate, worker-engines.

## Proven on BOTH OSes — `test-crossos.ps1` = ALL PASS on each

- **Windows** (pwsh): `Win32_Process.Create` detach, all helpers, worker-engines Windows path.
- **Linux** (WSL Ubuntu 22.04, pwsh 7.6.3, `$IsWindows=$false`): the real Unix branches —
  `ps -axww` enumeration parse, `nohup` detached spawn returning the correct live pid, leaves-first
  `Stop-Process` tree kill, worker-engines resolving `/usr/bin/node` via PATH, `?? $HOME` fallback.
- **Windows regression**: `test-autopro-reliability.ps1` → ALL PASS (37) — behaviour unchanged.

### Two bugs the Linux run caught (the Windows box could not)
1. **`Start-DetachedProcess` returned a dead pid.** `cd '$q' && nohup <cmd> &` backgrounds the whole
   `&&`-compound, so `$!` was a short-lived subshell that exited and orphaned the worker under a
   different pid. Fixed: `cd` is now its own statement (`cd '$q' || exit 1; nohup … &`) so only the
   worker is backgrounded and `$!` is its real pid. Verified on WSL (pid stays alive).
2. **`@($list)` over `List[object]` throws "Argument types do not match" on pwsh 7.6+** (tolerated by
   older pwsh, so green on Windows). Fixed: `Get-AutoproProcessList` returns `$list.ToArray()`.

To run the proof yourself on Unix:
```
pwsh -File scripts/test-crossos.ps1     # (pwsh 7 required)
```

### Minor / cosmetic remainders (do not block a Unix run)
- `cmd.exe /c start` runner fallback in `launch-showtime.ps1` — only reached if the primary
  (ported) `Start-DetachedProcess` fails; needs a Unix equivalent for full parity.
- `chrome.exe` / `ProgramFiles` board-open in `launch-ultra.ps1` / `showtime-open-board.ps1` —
  best-effort "open the board in a browser"; degrades gracefully if absent.
- A few `Write-Output "…$RepoDir\.claude\…"` display strings still print backslashes on Unix
  (cosmetic; the actual file ops use the ported forward-slash paths).
