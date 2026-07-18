# Share autopro with a mate (Claude)

**Important:** Autopro is a **local skill folder** on *your* machine.  
Claude does **not** pull it from the cloud. Your junctions/Claude.md only help **you**.

Your mate’s Claude said “no autopro” because **their PC has no skill files** — not because the skill is fake.

---

## What they need

1. **Claude Code** (or Claude Desktop with Code / Cowork that reads `~/.claude/skills`), **not** only claude.ai chat with no local skills.
2. A copy of the `autopro` skill folder on **their** disk.
3. Optional: ledger + Node if they actually run Show Time / the runner.

---

## Easiest: send them the zip

You (Daniel) run once:

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\autopro\scripts\pack-for-mate.ps1"
```

That drops something like:

`Desktop\autopro-skill-for-mate.zip`

Send that zip (Drive, AirDrop, Slack, USB…).

---

## Mate install (Windows)

```powershell
# 1) Unzip wherever, then:
$zipRoot = "$env:USERPROFILE\Downloads\autopro"   # folder that contains SKILL.md
$dest    = Join-Path $env:USERPROFILE '.claude\skills\autopro'

New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
Copy-Item -LiteralPath $zipRoot -Destination $dest -Recurse -Force

# 2) Multi-host junctions on *their* PC (Cursor / Antigravity / Codex if they use them)
& pwsh -NoProfile -File (Join-Path $dest 'scripts\install-hosts.ps1')

# 3) Restart Claude Code / Desktop
```

**Mac/Linux mate:**

```bash
mkdir -p ~/.claude/skills
# unzip so ~/.claude/skills/autopro/SKILL.md exists
# optional: ln -s ~/.claude/skills/autopro ~/.agents/skills/autopro
```

---

## Mate check (they paste this in Claude)

> Do you have an **autopro** skill? Don't install. Yes/no only, then one sentence on what it does.  
> Path should be `~/.claude/skills/autopro/SKILL.md`.

Expected:

> **Yes.** Local skill that arms an autonomous ledger runner and optional Show Time board after the ledger is approved.

If still **No**:

- They’re on **claude.ai web** without local skills → skill files alone won’t appear in the skills list; they need **Claude Code**, or paste `references/CHATGPT-CUSTOM-INSTRUCTIONS.md` style text into Project instructions (awareness only, no real arm).
- Skill folder not under `~/.claude/skills/autopro/SKILL.md` (wrong unzip layout: SKILL.md must not be nested one level too deep).
- App not restarted after copy.

---

## What autopro will *not* do on their machine without extra setup

| Piece | Need |
|--------|------|
| Skill visible | Copy of folder + Claude Code |
| Run `launch-showtime.ps1` | PowerShell + Node |
| Actually finish ledger slices | `claude` CLI + approved ledger in a repo |
| Show Time board | Node starts `theater-server.mjs` → `http://127.0.0.1:8770/` |

Sharing the skill ≠ sharing your ledger, API keys, or running jobs on your PC.

---

## Git option (better for updates)

If the skill lives in a private/public repo path (e.g. loopletai `.claude/skills/autopro` junctioned to home), mate can:

```powershell
git clone <repo>
# then junction or copy .claude/skills/autopro → %USERPROFILE%\.claude\skills\autopro
```

Or keep the skill in a tiny dedicated repo `looplet-autopro-skill` and both of you pull updates.
