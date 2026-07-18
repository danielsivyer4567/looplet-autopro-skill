# Autopro — multi-host visibility

Canonical package:

```
%USERPROFILE%\.claude\skills\autopro\
```

## One command (all local hosts)

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.claude\skills\autopro\scripts\install-hosts.ps1" `
  -RepoDir "<YOUR-REPO-ROOT>"
```

Creates **junctions** (not copies) into:

| Host | Path |
|------|------|
| Agents standard | `~\.agents\skills\autopro` |
| Cursor | `~\.cursor\skills\autopro` |
| Codex / ChatGPT Codex | `~\.codex\skills\autopro` |
| Grok | `~\.grok\skills\autopro` |
| Antigravity global | `~\.gemini\skills\autopro` |
| Antigravity config | `~\.gemini\config\skills\autopro` |
| Antigravity legacy | `~\.gemini\antigravity\skills\autopro` |
| Workspace | `<repo>\.agents\skills\autopro` |
| Workspace Claude | `<repo>\.claude\skills\autopro` |

Claude Code / Claude Desktop (Code sessions) already use `~\.claude\skills\`.

## ChatGPT web

No skill filesystem. Paste `CHATGPT-CUSTOM-INSTRUCTIONS.md` into:

- ChatGPT **Project** instructions, or
- a **Custom GPT** instructions field, or
- account **Custom instructions** (shorter version)

## After install

Restart the host app (Cursor / Antigravity / Codex / Claude Desktop) so skill scanners rescan.

Then ask: `do you have access to an autopro skill? don't install, just yes/no and explain`
