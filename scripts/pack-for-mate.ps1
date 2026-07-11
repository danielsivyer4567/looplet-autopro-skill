<#
  pack-for-mate.ps1 — zip the autopro skill for a friend to install on their Claude.

  Output: Desktop\autopro-skill-for-mate.zip
  Includes: SKILL.md, scripts, theater, references (incl. SHARE-WITH-MATE.md)
#>
$ErrorActionPreference = 'Stop'
$Canonical = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$desk = [Environment]::GetFolderPath('Desktop')
if (-not $desk) { $desk = Join-Path $env:USERPROFILE 'Desktop' }
$zip = Join-Path $desk 'autopro-skill-for-mate.zip'
$stage = Join-Path $env:TEMP ('autopro-pack-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$inner = Join-Path $stage 'autopro'

if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $inner | Out-Null

# Copy skill tree; skip junk
$robolog = Join-Path $env:TEMP 'autopro-pack-robo.log'
& robocopy $Canonical $inner /E /NFL /NDL /NJH /NJS /nc /ns /np `
  /XD node_modules .git __pycache__ `
  /XF *.pid *.log | Out-Null

# Ensure mate docs present
$share = Join-Path $inner 'references\SHARE-WITH-MATE.md'
if (-not (Test-Path $share)) {
  throw "Missing SHARE-WITH-MATE.md — pack incomplete"
}

# README on zip root
@"
# autopro skill — install on your machine

1. Unzip so you have a folder ``autopro`` containing ``SKILL.md``.
2. Copy that folder to:
   - Windows: ``%USERPROFILE%\.claude\skills\autopro``
   - Mac/Linux: ``~/.claude/skills/autopro``
3. Optional multi-host:
   ``pwsh -File scripts\install-hosts.ps1``
4. Restart Claude Code / Claude Desktop.
5. Ask: "do you have an autopro skill? don't install, yes/no + one sentence"

Full notes: ``references\SHARE-WITH-MATE.md``
"@ | Set-Content (Join-Path $stage 'README-INSTALL.txt') -Encoding utf8

if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
Remove-Item $stage -Recurse -Force

Write-Output "ZIP=$zip"
Write-Output "SIZE_MB=$([math]::Round((Get-Item $zip).Length/1MB, 2))"
Write-Output 'Send this zip to your mate. Their Claude will not see your PC skills until they install locally.'
