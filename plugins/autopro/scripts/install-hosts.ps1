<#
  install-hosts.ps1 — make `autopro` discoverable on every agent host on this PC.

  Canonical skill:
    %USERPROFILE%\.claude\skills\autopro

  Junctions (not copies) so one edit updates all hosts:
    Claude Code / Desktop (cowork code)  → already canonical
    Cursor                               → %USERPROFILE%\.cursor\skills\autopro
    Agents standard                      → %USERPROFILE%\.agents\skills\autopro
    Codex / ChatGPT-Codex desktop        → %USERPROFILE%\.codex\skills\autopro
    Grok                                 → %USERPROFILE%\.grok\skills\autopro
    Antigravity (global)                 → %USERPROFILE%\.gemini\skills\autopro
                                         → %USERPROFILE%\.gemini\config\skills\autopro
                                         → %USERPROFILE%\.gemini\antigravity\skills\autopro
    Workspace (loopletai)                → <repo>\.agents\skills\autopro
                                         → <repo>\.claude\skills\autopro  (copy/sync optional)

  ChatGPT web has no local skill folder — see references/CHATGPT-CUSTOM-INSTRUCTIONS.md

  Usage:
    pwsh -NoProfile -File install-hosts.ps1
    pwsh -NoProfile -File install-hosts.ps1 -RepoDir "<YOUR-REPO-ROOT>"
#>
param(
  [string]$RepoDir = '',
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$Canonical = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SkillMd = Join-Path $Canonical 'SKILL.md'
if (-not (Test-Path -LiteralPath $SkillMd)) {
  throw "Canonical skill missing SKILL.md at $Canonical"
}

function Ensure-Junction([string]$LinkPath, [string]$Target) {
  $parent = Split-Path $LinkPath -Parent
  if (-not (Test-Path -LiteralPath $parent)) {
    if ($WhatIf) {
      Write-Output "WHATIF mkdir $parent"
    } else {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
  }

  if (Test-Path -LiteralPath $LinkPath) {
    $item = Get-Item -LiteralPath $LinkPath -Force
    if ($item.LinkType -eq 'Junction' -or $item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
      $current = $null
      try { $current = $item.Target } catch {}
      if ($current -is [array]) { $current = $current[0] }
      if ("$current" -eq $Target) {
        Write-Output "OK already $LinkPath -> $Target"
        return
      }
      if ($WhatIf) {
        Write-Output "WHATIF remove old link $LinkPath (was $current)"
      } else {
        cmd /c "rmdir `"$LinkPath`"" | Out-Null
      }
    } else {
      Write-Output "SKIP real folder (not junction): $LinkPath — remove manually if you want a link"
      return
    }
  }

  if ($WhatIf) {
    Write-Output "WHATIF junction $LinkPath -> $Target"
    return
  }

  # New-Item -ItemType Junction works on modern PowerShell / Windows
  try {
    New-Item -ItemType Junction -Path $LinkPath -Target $Target | Out-Null
    Write-Output "LINK $LinkPath -> $Target"
  } catch {
    # Fallback cmd mklink /J
    $out = cmd /c "mklink /J `"$LinkPath`" `"$Target`"" 2>&1
    Write-Output "LINK(cmd) $LinkPath -> $Target  ($out)"
  }
}

$targets = @(
  (Join-Path $env:USERPROFILE '.agents\skills\autopro'),
  (Join-Path $env:USERPROFILE '.cursor\skills\autopro'),
  (Join-Path $env:USERPROFILE '.codex\skills\autopro'),
  (Join-Path $env:USERPROFILE '.grok\skills\autopro'),
  (Join-Path $env:USERPROFILE '.gemini\skills\autopro'),
  (Join-Path $env:USERPROFILE '.gemini\config\skills\autopro'),
  (Join-Path $env:USERPROFILE '.gemini\antigravity\skills\autopro')
)

Write-Output "CANONICAL=$Canonical"
foreach ($t in $targets) {
  Ensure-Junction -LinkPath $t -Target $Canonical
}

# Workspace scopes (Antigravity + Cursor project skills)
if (-not $RepoDir) {
  $guess = '<YOUR-REPO-ROOT>'
  if (Test-Path -LiteralPath $guess) { $RepoDir = $guess }
}
if ($RepoDir -and (Test-Path -LiteralPath $RepoDir)) {
  Ensure-Junction -LinkPath (Join-Path $RepoDir '.agents\skills\autopro') -Target $Canonical
  # Keep repo .claude/skills/autopro as junction too if not a real divergent tree
  $repoClaude = Join-Path $RepoDir '.claude\skills\autopro'
  if (Test-Path -LiteralPath $repoClaude) {
    $item = Get-Item -LiteralPath $repoClaude -Force
    $isLink = ($item.LinkType -eq 'Junction') -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if (-not $isLink) {
      # Real mirror from earlier work — replace with junction so hosts don't diverge
      if ($WhatIf) {
        Write-Output "WHATIF replace real folder $repoClaude with junction"
      } else {
        # Only replace if it looks like our skill package (has SKILL.md)
        if (Test-Path -LiteralPath (Join-Path $repoClaude 'SKILL.md')) {
          Remove-Item -LiteralPath $repoClaude -Recurse -Force
          Ensure-Junction -LinkPath $repoClaude -Target $Canonical
        } else {
          Write-Output "SKIP unexpected $repoClaude"
        }
      }
    } else {
      Ensure-Junction -LinkPath $repoClaude -Target $Canonical
    }
  } else {
    Ensure-Junction -LinkPath $repoClaude -Target $Canonical
  }
} else {
  Write-Output 'REPO_DIR=not set — skipped workspace junctions'
}

Write-Output ''
Write-Output 'ChatGPT web: no local skills API — paste references/CHATGPT-CUSTOM-INSTRUCTIONS.md into a Project or Custom GPT.'
Write-Output 'Claude Desktop Code: uses ~/.claude/skills (canonical) + Claude.md skill triggers.'
Write-Output 'DONE'
