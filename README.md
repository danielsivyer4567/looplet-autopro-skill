# Looplet Autopro (Agent Skill)

One-key **autonomous ledger runner** + optional **Show Time** board for AI coding agents.

## Install (`npx skills`)

**Do not use `--all` / `--agent *` with `-g`.** PromptScript and Eve reject global installs and the CLI reports “Failed to install 1” even when the skill landed for other agents.

### Recommended (global, supported agents)

```bash
npx skills add danielsivyer4567/looplet-autopro-skill@autopro -g -y \
  --agent claude-code --agent cursor --agent codex --agent antigravity
```

Windows (PowerShell):

```powershell
npx skills add danielsivyer4567/looplet-autopro-skill@autopro -g -y `
  --agent claude-code --agent cursor --agent codex --agent antigravity
```

That installs to `~/.agents/skills/autopro` and symlinks/copies for those hosts.

### Grok / multi-host junctions (Windows)

After the skill exists under `~/.agents/skills/autopro` or `~/.claude/skills/autopro`:

```powershell
pwsh -File "$env:USERPROFILE\.claude\skills\autopro\scripts\install-hosts.ps1" -RepoDir <your-repo>
```

That junctions into Cursor, Codex, Grok, Antigravity, workspace, etc.

### Project-only (no `-g`)

```bash
npx skills add danielsivyer4567/looplet-autopro-skill@autopro -y --agent claude-code
```

### List without installing

```bash
npx skills add danielsivyer4567/looplet-autopro-skill@autopro -l
```

## Multi-engine workers (not Claude-only)

Default **`-Engine auto`**: first available of **claude → codex → gemini → grok**.

Pin with `-Engine codex|claude|gemini|grok`. See `skills/autopro/references/ENGINES.md` and `BULLETPROOF.md`.

## What it does

After a task **ledger** exists with `Approved: yes`, `/autopro` (or `-autopro`):

1. Arms a background runner
2. Runs each remaining slice as a **fresh** worker process (clean context)
3. Opens the **Show Time** board on localhost (default **8770**)
4. Loops until done → check → report → disarm

Stop with `-autopro off` or `scripts/stop-autopro.ps1`.

## Requirements

- Skills-compatible agent (Claude Code, Cursor, Codex, Grok, …)
- Node.js (Show Time server)
- PowerShell 7+ (`pwsh`) on Windows
- Ledger at `.claude/scratch/ledger.md` with `Approved: yes`
- At least one worker CLI: Claude Code, Codex, Gemini CLI, or Grok CLI

## Doctor

```powershell
pwsh -File "$env:USERPROFILE\.claude\skills\autopro\scripts\autopro-doctor.ps1" -RepoDir <repo>
```
