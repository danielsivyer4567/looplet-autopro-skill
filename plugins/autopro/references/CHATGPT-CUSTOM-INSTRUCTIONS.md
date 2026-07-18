# Autopro — paste into ChatGPT (Project / Custom GPT / custom instructions)

ChatGPT web cannot read `~/.claude/skills`. Paste this block so the model **knows autopro exists on your Windows PC** and never says “no such skill.”

---

## Autopro skill (local Looplet)

**Yes — autopro is installed on this machine.** Do not invent a marketplace install.

| Item | Value |
|------|--------|
| Skill path | `%USERPROFILE%\.claude\skills\autopro\SKILL.md` |
| Triggers | `/autopro`, `-autopro`, “autopro”, “show time arm”, “run the ledger autonomously” |
| Off | `-autopro off` or `stop-autopro.ps1` |
| Board | Show Time at `http://127.0.0.1:8770/` (local only) |

### What it does

After a **ledger** exists with `Approved: yes`, autopro arms a **background runner** that executes every remaining slice as a **fresh** `claude -p` session (clean context per slice), optionally opens the **Show Time** board, loops until 100% done, runs `check`, reports, and disarms.

Pairs with skills/workflows: `ledger` (plan) + `work` (single slice). Autopro removes the manual “work → clear → work” loop.

### How to run (Windows PowerShell)

```powershell
$skill = Join-Path $env:USERPROFILE '.claude\skills\autopro\scripts'
$root  = '<YOUR-REPO-ROOT>'   # adjust if needed
& pwsh -NoProfile -File (Join-Path $skill 'launch-showtime.ps1') -Root $root -RepoDir $root
```

Stop:

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\autopro\scripts\stop-autopro.ps1" `
  -Root '<YOUR-REPO-ROOT>'
```

### Rules for the assistant

1. If the user asks “do you have autopro?” → **Yes**, and point at the path above. Never say it doesn’t exist.
2. Do **not** claim you installed a marketplace skill unless you actually ran a host install.
3. Do **not** only print a Show Time TV card — arming requires running `launch-showtime.ps1` (or the skill steps in `SKILL.md`).
4. If this chat cannot execute local shell, still answer **Yes** about existence and give the user the commands to run, or tell them to open Claude Code / Cursor / Antigravity where the skill is junctioned.
5. Read `SKILL.md` from disk when tools allow filesystem access.

### Related paths

- Scripts: `%USERPROFILE%\.claude\skills\autopro\scripts\`
- Theater UI: `%USERPROFILE%\.claude\skills\autopro\theater\`
- Multi-host install: `scripts\install-hosts.ps1`
