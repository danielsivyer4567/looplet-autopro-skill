<!--
  CHAT-ONLY TV when autopro is armed.

  Fixed-width square: outer content = 40 cols, screen = 34 cols.
  Swap board URL/port if launch printed another.

  NO ANSI. Hosts strip ESC → "[94mLOOPLET[0m" garbage.

  Rules:
  - Board URL ONCE as bare http(s). Never [url](url).
  - Do NOT wrap the TV in a fenced ``` code block.
  - No second Board line under the set.
-->

```
      ╔════════════════════════════════════════╗
      ║          LOOPLET    CHANNEL 3          ║
      ║  ┌──────────────────────────────────┐  ║
      ║  │                                  │  ║
      ║  │             ON AIR               │  ║
      ║  │                                  │  ║
      ║  │         S H O W  T I M E         │  ║
      ║  │                                  │  ║
      ║  │      http://127.0.0.1:8770/      │  ║
      ║  │                                  │  ║
      ║  │    autonomous ledger  ● LIVE    │  ║
      ║  │                                  │  ║
      ║  └──────────────────────────────────┘  ║
      ║     (  ) VOL          CHANNEL (  )     ║
      ║            ─────═════─────             ║
      ╚════════════════════════════════════════╝
                ▔▔▔▔                   ▔▔▔▔
```

(Fenced only in this template file for docs. **In chat, print the TV unfenced** so the URL can autolink.)

# SHOWTIME · ON AIR

**Manual log** (terminal watch):

```powershell
Get-Content ".claude\scratch\autopro.log" -Wait
```

**Needs-you watch** (chat bridge — launch usually starts this minimized):

```powershell
pwsh -NoProfile -File "$HOME/.claude/skills/autopro/scripts/autopro-watch.ps1" `
  -Root "<YOUR-REPO-ROOT>" -UntilDisarmed -AlsoLog
```
