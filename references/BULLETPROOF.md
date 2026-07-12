# AutoPro multi-engine — bulletproof checklist

Run after engine/adapter changes and before trusting a long unattended arm.

## Automated gates (must be green)

```powershell
$s = "$env:USERPROFILE\.claude\skills\autopro\scripts"
pwsh -NoProfile -File "$s\test-worker-engines.ps1"      # offline unit
pwsh -NoProfile -File "$s\smoke-worker-engines.ps1"     # --version + argv shapes
pwsh -NoProfile -File "$s\test-autopro-reliability.ps1" # parse + boot + gate
pwsh -NoProfile -File "$s\autopro-doctor.ps1" -RepoDir <repo>
```

## Headless invariants (do not regress)

| Rule | Why |
|------|-----|
| Never spawn npm `*.ps1` / `*.cmd` shims via ProcessStartInfo | Argv collapse on Windows |
| Always `RedirectStandardInput=$true` then **Close()** (empty EOF) | Codex hangs on open stdin |
| Codex: prompt on **argv**, not `-` stdin | `-` hung in smoke |
| Grok: always **`-p` / `--single`** headless | Positional opens TUI, never exits |
| Gemini: **`auto_edit`**, not `-y` | Admin `disableYolo` common |
| Theater + runner detach via **Win32_Process.Create** | Job-object kill on parent exit |
| CIM scans use **OperationTimeoutSec** | Bare Win32_Process enum hangs |
| OpenRegister = join + **auto-approve** + session POST | Join gate otherwise blocks unattended |
| Dedupe ignores **dead-pid** stalled/running lanes | Re-arm must not attach to zombies |

## Live arm health

```powershell
# Flag present?
Get-ChildItem <repo>\.claude\scratch\autopro-on*

# Runner + real worker (codex.exe is the agent; node is wrapper)
Get-Process pwsh | ? { ... }   # or check autopro.log runnerPid=
Get-Process codex,node,grok,claude -EA SilentlyContinue

# Board
Invoke-RestMethod http://127.0.0.1:8770/api/health
# Token: %USERPROFILE%\.claude\scratch\autopro-theater\server.token

# Log
Get-Content <repo>\.claude\scratch\autopro.log -Wait -Tail 40
```

Quiet log during a long slice is **normal** (JSON buffered until exit). Watch **codex.exe** / child CPU+RAM, not only node.

## Stop cleanly

```powershell
pwsh -File "$env:USERPROFILE\.claude\skills\autopro\scripts\stop-autopro.ps1" -Root <repo>
```

## Known residual risks (honest)

1. **Gemini** may still hang or refuse depending on admin policy / auth — smoke PONG not always free.
2. **Full agentic Grok** is `-p` + `--max-turns 80` (not TUI multi-session).
3. **Board restart** mid-run: runner retries once on 401/403/404/refused; if board stays down, work continues, UI goes dark.
4. **Ollama** is not agentic by default — explicit `-AllowOllama` only.
5. **Slice verifier** uses a second full worker pass — can dominate wall clock after each slice.

## Arm recipe

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\autopro\scripts\launch-showtime.ps1" `
  -Root <root> -RepoDir <repo> `
  -AllowDangerousSkipPermissions -IAcceptUnattendedRisk `
  -Engine auto   # or claude|codex|gemini|grok
```
