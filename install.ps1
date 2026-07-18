<#
  install.ps1 — install the AutoPro skill into $HOME/.claude/skills/autopro on Windows (or any OS
  where you already have pwsh). Idempotent: backs up any existing install first.
  Usage:  pwsh -NoProfile -File install.ps1
#>
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$dest = Join-Path $HOME '.claude/skills/autopro'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if (-not (Test-Path -LiteralPath (Join-Path $src 'SKILL.md'))) {
  throw 'install.ps1: run me from the AutoPro package dir (SKILL.md not found next to me).'
}

if (Test-Path -LiteralPath $dest) {
  # NOTE: back up OUTSIDE skills/ so the backup isn't registered as a phantom duplicate skill.
  $bak = Join-Path $HOME ".claude/autopro-backups/autopro.bak-$stamp"
  New-Item -ItemType Directory -Force -Path (Split-Path $bak -Parent) | Out-Null
  Copy-Item -LiteralPath $dest -Destination $bak -Recurse -Force
  Write-Host "backed up existing skill -> $bak"
  Remove-Item -LiteralPath $dest -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -LiteralPath (Join-Path $src 'SKILL.md') -Destination $dest -Force
foreach ($d in @('scripts', 'references', 'theater')) {
  $p = Join-Path $src $d
  if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $dest -Recurse -Force }
}
Write-Host "AutoPro skill installed -> $dest"

# pwsh is obviously present (you're running it). Just confirm the version is 7+.
if ($PSVersionTable.PSVersion.Major -lt 7) {
  Write-Warning 'AutoPro needs PowerShell 7 (pwsh), not Windows PowerShell 5.1. Install: winget install Microsoft.PowerShell'
}

Write-Host ''
Write-Host 'Done. Next: create + approve a ledger, then type /autopro in Claude Code.'
Write-Host ("Stop anytime:  pwsh -NoProfile -File `"{0}/scripts/stop-autopro.ps1`" -All" -f $dest)
