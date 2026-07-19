<#
  install.ps1 — install the AutoPro skill into $HOME/.claude/skills/autopro on Windows (or any OS
  where you already have pwsh). Idempotent: backs up any existing install first.

  Preferred (inspect first):
    git clone https://github.com/danielsivyer4567/looplet-autopro-skill.git
    cd looplet-autopro-skill
    pwsh -NoProfile -File install.ps1

  Usage:
    pwsh -NoProfile -File install.ps1
    pwsh -NoProfile -File install.ps1 -DryRun     # print plan; no copy
    pwsh -NoProfile -File install.ps1 -Version    # print package version; exit

  See TRUST.md for clone-vs-pipe risk, checksums, rollback.
#>
param(
  [switch]$DryRun,
  [switch]$Version
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$skillSrc = Join-Path $src 'plugins/autopro'          # the skill lives inside the plugin dir
$dest = Join-Path $HOME '.claude/skills/autopro'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$versionFile = Join-Path $src 'VERSION'
$pkgVersion = if (Test-Path -LiteralPath $versionFile) {
  (Get-Content -LiteralPath $versionFile -Raw).Trim()
} else { 'unknown' }

if ($Version) {
  Write-Output ("AUTOPRO_VERSION={0}" -f $pkgVersion)
  Write-Output ("PACKAGE_ROOT={0}" -f $src)
  exit 0
}

if (-not (Test-Path -LiteralPath (Join-Path $skillSrc 'SKILL.md'))) {
  throw 'install.ps1: run me from the AutoPro package dir (plugins/autopro/SKILL.md not found).'
}

Write-Output ("AUTOPRO_VERSION={0}" -f $pkgVersion)
Write-Output ("INSTALL_SRC={0}" -f $skillSrc)
Write-Output ("INSTALL_DEST={0}" -f $dest)

if ($DryRun) {
  $exists = Test-Path -LiteralPath $dest
  Write-Output 'DRY_RUN=1'
  Write-Output ("DRY_RUN_DEST_EXISTS={0}" -f ($(if ($exists) { '1' } else { '0' })))
  if ($exists) {
    Write-Output ("DRY_RUN_BACKUP_WOULD= ~/.claude/autopro-backups/autopro.bak-{0}" -f $stamp)
  }
  Write-Output 'DRY_RUN_ACTION=would copy plugins/autopro → ~/.claude/skills/autopro (SKILL.md + scripts + references + theater)'
  Write-Output 'DRY_RUN_NO_NETWORK=1'
  exit 0
}

if (Test-Path -LiteralPath $dest) {
  # NOTE: back up OUTSIDE skills/ so the backup isn't registered as a phantom duplicate skill.
  $bak = Join-Path $HOME ".claude/autopro-backups/autopro.bak-$stamp"
  New-Item -ItemType Directory -Force -Path (Split-Path $bak -Parent) | Out-Null
  Copy-Item -LiteralPath $dest -Destination $bak -Recurse -Force
  Write-Host "backed up existing skill -> $bak"
  # Prefer robocopy-style overlay if locked files block Remove-Item
  try {
    Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction Stop
  } catch {
    Write-Warning "Remove-Item failed (file lock?) — overlaying instead: $_"
  }
}

New-Item -ItemType Directory -Force -Path $dest | Out-Null
# Copy SKILL.md, rewriting the plugin-root placeholder to the actual install dir (non-plugin install).
$skillMd = [IO.File]::ReadAllText((Join-Path $skillSrc 'SKILL.md')).Replace('${CLAUDE_PLUGIN_ROOT}', $dest)
[IO.File]::WriteAllText((Join-Path $dest 'SKILL.md'), $skillMd)
foreach ($d in @('scripts', 'references', 'theater')) {
  $p = Join-Path $skillSrc $d
  if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $dest -Recurse -Force }
}
# Surface package trust files next to the skill (optional; agents only need SKILL.md tree)
foreach ($f in @('VERSION', 'CHANGELOG.md', 'TRUST.md', 'SHA256SUMS.txt')) {
  $pf = Join-Path $src $f
  if (Test-Path -LiteralPath $pf) {
    Copy-Item -LiteralPath $pf -Destination (Join-Path $dest $f) -Force
  }
}
Write-Host "AutoPro skill installed -> $dest (v$pkgVersion)"

# pwsh is obviously present (you're running it). Just confirm the version is 7+.
if ($PSVersionTable.PSVersion.Major -lt 7) {
  Write-Warning 'AutoPro needs PowerShell 7 (pwsh), not Windows PowerShell 5.1. Install: winget install Microsoft.PowerShell'
}

Write-Host ''
Write-Host 'Done. Next: create + approve a ledger, then type /autopro in Claude Code.'
Write-Host ("Dry-run arm plan:  pwsh -NoProfile -File `"{0}/scripts/launch-autopro.ps1`" -Root <repo> -RepoDir <repo> -DryRun" -f $dest)
Write-Host ("Stop anytime:  pwsh -NoProfile -File `"{0}/scripts/stop-autopro.ps1`" -All" -f $dest)
Write-Host 'Trust / rollback: see TRUST.md in the package repo (or VERSION next to the skill).'
