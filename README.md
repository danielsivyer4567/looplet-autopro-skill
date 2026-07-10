# Looplet Autopro (Agent Skill)

One-key **autonomous ledger runner** + optional **Show Time** board for AI coding agents.

## Install (`npx skills`)

```bash
npx skills add danielsivyer4567/looplet-autopro-skill@autopro -g -y
```

Install everything in this repo:

```bash
npx skills add danielsivyer4567/looplet-autopro-skill -g -y
```

List skills without installing:

```bash
npx skills add danielsivyer4567/looplet-autopro-skill -l
```

## What it does

After a task **ledger** exists with `Approved: yes`, `/autopro` (or `-autopro`):

1. Arms a background runner
2. Runs each remaining slice as a **fresh** `claude -p` session (clean context)
3. Opens the **Show Time** board on localhost (default **8770**)
4. Loops until done → `check` → report → disarm

Stop with `-autopro off` or `scripts/stop-autopro.ps1`.

## Requirements

- A skills-compatible agent (Claude Code, Cursor, Codex, Antigravity, …)
- Node.js (Show Time server)
- PowerShell 7+ on Windows (`pwsh`)
- Project ledger at `.claude/scratch/ledger.md` with `Approved: yes`

## After install

Restart the agent host, then ask:

> Do you have an **autopro** skill? Don't install — yes/no and what it does.

## Arm (example)

```powershell
$candidates = @(
  (Join-Path $env:USERPROFILE '.claude\skills\autopro\scripts'),
  (Join-Path $env:USERPROFILE '.agents\skills\autopro\scripts')
)
$skill = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$root = (Get-Location).Path
& pwsh -NoProfile -File (Join-Path $skill 'launch-showtime.ps1') -Root $root -RepoDir $root
```

## Layout

```
skills/
  autopro/
    SKILL.md
    scripts/
    theater/
    references/
```

## License

MIT
