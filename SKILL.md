---
name: autopro
description: "One skill for autonomous ledger execution + Show Time (Looplet). Default AUTO: pick serial vs ultra from how big the ledger is (open slices). Force with `-autopro serial` or `-autopro ultra`. Serial = one writer, one FRESH worker process per slice. Ultra = parallel bands + worktrees. Same engines, board, stop. `-autopro off` stops it. Pairs with `ledger` and `work`."
trigger: /autopro
---

# autopro + Show Time (Looplet)

> **You are looking at the package-root skill card.**  
> Claude Code loads the **installed** skill at `~/.claude/skills/autopro/SKILL.md`.  
> That file is copied from the **canonical skill tree**:
>
> **[`plugins/autopro/SKILL.md`](./plugins/autopro/SKILL.md)** ← full instructions, scripts, theater, references
>
> Why nested? This repo is also a **Claude Code marketplace plugin** (see `.claude-plugin/marketplace.json` → `source: ./plugins/autopro`). Install flattens `plugins/autopro/*` into `~/.claude/skills/autopro/`.

## Quick map

| Path | Role |
|------|------|
| **This file** (`SKILL.md` at repo root) | Discoverability for humans + skill indexes browsing GitHub |
| [`plugins/autopro/SKILL.md`](./plugins/autopro/SKILL.md) | **Source of truth** for agent behaviour |
| `~/.claude/skills/autopro/SKILL.md` | What Claude Code actually loads after install |
| [`VERSION`](./VERSION) · [`CHANGELOG.md`](./CHANGELOG.md) · [`TRUST.md`](./TRUST.md) | Trust pack |
| [`README.md`](./README.md) | Install, serial vs ultra, safeguards, examples |

## What it does

| Call | Mode | Behaviour |
|------|------|-----------|
| `-autopro` / `/autopro` | **auto** | Open slices **&lt; 12 → serial**, **≥ 12 → ultra** |
| `-autopro serial` | force serial | One writer · fresh worker process per slice |
| `-autopro ultra` | force parallel | Worktree bands · capped concurrency |
| `-autopro off` | stop | `stop-autopro.ps1` |

## Install (preferred — no pipe-to-shell)

```bash
git clone https://github.com/danielsivyer4567/looplet-autopro-skill.git
cd looplet-autopro-skill
# Read: this file, plugins/autopro/SKILL.md, TRUST.md, install.ps1
pwsh -NoProfile -File install.ps1 -DryRun
pwsh -NoProfile -File install.ps1
```

Convenience (higher risk — remote bootstrap): see [TRUST.md](./TRUST.md). Pin with `AUTOPRO_REF=v1.1.1`.

## Dry-run (no arm)

```powershell
pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/launch-autopro.ps1" `
  -Root <repo> -RepoDir <repo> -DryRun
```

## Full skill body

→ **[plugins/autopro/SKILL.md](./plugins/autopro/SKILL.md)**
