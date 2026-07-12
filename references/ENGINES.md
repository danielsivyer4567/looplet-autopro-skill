# AutoPro multi-engine workers

Slice execution is **not Claude-only**. The runner spawns whatever agent CLI you pick (or auto-detect).

## Engines

| Engine | CLI | Unattended flags | Auto-pick | Notes |
|--------|-----|------------------|-----------|--------|
| **claude** | `claude.exe` | `--dangerously-skip-permissions` | 1st | Best-integrated; JSON usage/cost |
| **codex** | `node …/codex.js exec` | `--dangerously-bypass-approvals-and-sandbox` | 2nd | OpenAI Codex CLI |
| **gemini** | `node …/gemini.js` | `-y` (yolo) | 3rd | Google Gemini CLI |
| **grok** | `grok.exe` | `--always-approve` + `bypassPermissions` | 4th | Grok Build CLI |
| **ollama** | `ollama run` | local | **never** | Text-only — needs `-AllowOllama` |

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

## Tests

```powershell
pwsh -File "$env:USERPROFILE\.claude\skills\autopro\scripts\test-worker-engines.ps1"
```
