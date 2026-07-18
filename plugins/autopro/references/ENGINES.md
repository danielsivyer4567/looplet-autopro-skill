# AutoPro multi-engine workers

Slice execution is **not Claude-only**. The runner spawns whatever agent CLI you pick (or auto-detect).

## Engines

| Engine | CLI | Unattended flags | Auto-pick | Notes |
|--------|-----|------------------|-----------|--------|
| **claude** | `claude.exe` | `--dangerously-skip-permissions` | 1st | Best-integrated; JSON usage/cost |
| **codex** | `node …/codex.js exec` | `--dangerously-bypass-approvals-and-sandbox` | 2nd | Prompt on argv; empty stdin EOF (required) |
| **gemini** | `node …/gemini.js` | `--approval-mode auto_edit` | 3rd | Prefer auto_edit; admin may disable YOLO (`-y`) |
| **grok** | `grok.exe` | `--always-approve` + `bypassPermissions` + **`-p`** | 4th | Must use `-p` (positional hangs under CreateNoWindow); `--max-turns 80` |
| **ollama** | `ollama run` | local | **never** | Text-only — needs `-AllowOllama` |

### Headless gotchas (proven)

| Engine | Failure mode | Fix |
|--------|--------------|-----|
| **codex** | `Reading additional input from stdin…` forever | Redirect stdin + **close immediately** (empty EOF); prompt on argv |
| **grok** | Positional prompt never exits (TUI) | Use **`-p` / `--single`** for headless |
| **gemini** | `YOLO mode is disabled by administrator` | Use **`auto_edit`**, not `-y` |

Auto order: `claude → codex → gemini → grok`  
Override: `$env:AUTOPRO_ENGINE_ORDER = 'codex,gemini,claude'`

## Prompt and play

```powershell
# Doctor first (no arm)
pwsh -File "$env:USERPROFILE\.claude\skills\autopro\scripts\autopro-doctor.ps1" -RepoDir <repo>

# Arm with auto engine (default)
pwsh -File "$env:USERPROFILE\.claude\skills\autopro\scripts\launch-showtime.ps1" `
  -Root <root> -RepoDir <repo> `
  -AllowDangerousSkipPermissions -IAcceptUnattendedRisk

# Pin engine + model
… -Engine codex -Model o3
… -Engine gemini -Model gemini-2.5-pro
… -Engine grok -Model grok-4
… -Engine claude -Model sonnet
```

Env defaults:

| Env | Effect |
|-----|--------|
| `AUTOPRO_ENGINE` | Default when `-Engine auto` |
| `AUTOPRO_MODEL` | Default model pin |
| `AUTOPRO_ENGINE_ORDER` | Comma auto order |
| `AUTOPRO_VERIFIER_ENGINE` | Optional (pass as `-VerifierEngine`) |

## Why npm shims are banned

Windows `claude.ps1` / `codex.ps1` collapse ProcessStartInfo argv. Resolution always prefers:

- real `.exe`, or  
- `node path/to/package/bin.js …`

## Board

Heartbeats include `stats.engine` + `stats.model` so fleets show **which CLI** is burning credits.

## Safety

| Control | Default |
|---------|---------|
| Risk switches to arm | required (`-AllowDangerousSkipPermissions` + `-IAcceptUnattendedRisk`) |
| Max slice wall clock | **90 minutes** (`-MaxSliceMinutes 0` disables) |
| Stop orphans | `stop-autopro.ps1` kills all worker CLIs + pidfile |
| Board credit chips | engine + model on register and every heartbeat |

## Tests

```powershell
pwsh -File "$env:USERPROFILE\.claude\skills\autopro\scripts\test-worker-engines.ps1"
pwsh -File "$env:USERPROFILE\.claude\skills\autopro\scripts\smoke-worker-engines.ps1"
pwsh -File "$env:USERPROFILE\.claude\skills\autopro\scripts\test-autopro-reliability.ps1"
pwsh -File "$env:USERPROFILE\.claude\skills\autopro\scripts\autopro-doctor.ps1" -RepoDir <repo>
```
