#Requires -Version 7.0
<#
  launch-autopro.ps1 — ONE front door for AutoPro.

  Same skill, same Show Time board, same engines. Mode only changes concurrency:

    -Mode auto    (DEFAULT)  Pick from ledger size (how big the request is).
                             remaining slices < SerialMaxSlices → serial
                             remaining slices ≥ SerialMaxSlices → ultra

    -Mode serial             Force one writer, one fresh worker per slice.
                             → launch-showtime.ps1 + autopro-runner.ps1

    -Mode ultra|parallel     Force parallel bands (worktrees, capped concurrency).
                             → launch-ultra.ps1 + autopro-ultra.ps1

  Call sites:
    -autopro / /autopro              → auto (size-based)
    -autopro serial                  → force serial
    -autopro ultra | parallel        → force ultra
    -autopro off                     → stop-autopro.ps1 (not this file)

  Risk switches still required:
    -AllowDangerousSkipPermissions -IAcceptUnattendedRisk

  Size heuristic (tunable):
    -SerialMaxSlices 12   (default) — at/above this remaining count → ultra
    Env: AUTOPRO_SERIAL_MAX_SLICES, AUTOPRO_MODE=auto|serial|ultra
#>
param(
  [Parameter(Mandatory = $true)][string]$Root,
  [Parameter(Mandatory = $true)][string]$RepoDir,
  # auto = size-based (default). serial|ultra|parallel = force.
  [ValidateSet('auto', 'serial', 'ultra', 'parallel')]
  [string]$Mode = 'auto',
  # When Mode=auto: remaining open slices ≥ this → ultra, else serial.
  [ValidateRange(2, 200)]
  [int]$SerialMaxSlices = 12,
  [string]$Model = '',
  [string]$Engine = 'auto',
  [string]$VerifierEngine = '',
  [switch]$AllowOllama,
  [switch]$NoBrowser,
  [switch]$NoShowTime,
  [switch]$AllowDangerousSkipPermissions,
  [switch]$IAcceptUnattendedRisk,
  [switch]$AllowModelOnlyFinalCheck,
  [switch]$NoSliceVerifier,
  [string]$VerifierModel = '',
  [ValidateRange(0, 3)]
  [int]$VerifierRepairAttempts = 1,
  [ValidateRange(0, 480)]
  [int]$MaxSliceMinutes = 90,
  [int]$StaleAfterMinutes = 30,
  [switch]$NoWatch,
  # Ultra-only knobs (ignored in serial)
  [int]$BandSize = 5,
  [int]$MaxConcurrency = 3,
  [ValidateSet('even', 'pack')][string]$SplitMode = 'even',
  [switch]$UnblockPaused,
  [int]$MaxBandMinutes = 120,
  [int]$StallMinutes = 12,
  [switch]$RequireBoard
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

# Env overrides when caller left defaults
if ($env:AUTOPRO_MODE -and $Mode -eq 'auto') {
  $m = $env:AUTOPRO_MODE.Trim().ToLowerInvariant()
  if ($m -in @('auto', 'serial', 'ultra', 'parallel')) { $Mode = $m }
}
if ($env:AUTOPRO_SERIAL_MAX_SLICES -and $env:AUTOPRO_SERIAL_MAX_SLICES -match '^\d+$') {
  $SerialMaxSlices = [Math]::Max(2, [int]$env:AUTOPRO_SERIAL_MAX_SLICES)
}

if ($Mode -eq 'parallel') { $Mode = 'ultra' }

function Get-LedgerOpenSliceCount([string]$Repo) {
  $ledger = Join-Path $Repo '.claude/scratch/ledger.md'
  if (-not (Test-Path -LiteralPath $ledger)) { return 0 }
  $t = Get-Content -LiteralPath $ledger -Raw -ErrorAction SilentlyContinue
  if (-not $t) { return 0 }
  $id = '(?:SC-\d+|SD-[\w-]+|H\d+|P\d+[-\w]*)'
  $pending = ([regex]::Matches($t, "(?m)^##\s+$id[^\n]*\[pending\]")).Count
  $inprog = ([regex]::Matches($t, "(?m)^##\s+$id[^\n]*\[in-progress\]")).Count
  return ($pending + $inprog)
}

$openSlices = Get-LedgerOpenSliceCount -Repo $RepoDir
$resolvedFrom = $Mode
if ($Mode -eq 'auto') {
  if ($openSlices -ge $SerialMaxSlices) {
    $Mode = 'ultra'
    $resolvedFrom = "auto(open=$openSlices≥$SerialMaxSlices→ultra)"
  } else {
    $Mode = 'serial'
    $resolvedFrom = "auto(open=$openSlices<$SerialMaxSlices→serial)"
  }
}

Write-Output ("AUTOPRO_MODE={0}" -f $Mode)
Write-Output ("AUTOPRO_MODE_RESOLVED_FROM={0}" -f $resolvedFrom)
Write-Output ("AUTOPRO_OPEN_SLICES={0}" -f $openSlices)
Write-Output ("AUTOPRO_SERIAL_MAX_SLICES={0}" -f $SerialMaxSlices)
Write-Output ("AUTOPRO_ENTRY=launch-autopro.ps1")
Write-Output ("ROOT={0}" -f $Root)
Write-Output ("REPO={0}" -f $RepoDir)

if ($Mode -eq 'serial') {
  $launch = Join-Path $here 'launch-showtime.ps1'
  if (-not (Test-Path -LiteralPath $launch)) {
    throw "Serial launcher missing: $launch"
  }
  $args = @(
    '-NoProfile', '-File', $launch,
    '-Root', $Root,
    '-RepoDir', $RepoDir,
    '-Engine', $Engine,
    '-VerifierRepairAttempts', $VerifierRepairAttempts,
    '-MaxSliceMinutes', $MaxSliceMinutes,
    '-StaleAfterMinutes', $StaleAfterMinutes
  )
  if ($Model) { $args += @('-Model', $Model) }
  if ($VerifierEngine) { $args += @('-VerifierEngine', $VerifierEngine) }
  if ($VerifierModel) { $args += @('-VerifierModel', $VerifierModel) }
  if ($AllowOllama) { $args += '-AllowOllama' }
  if ($NoBrowser) { $args += '-NoBrowser' }
  if ($NoShowTime) { $args += '-NoShowTime' }
  if ($AllowDangerousSkipPermissions) { $args += '-AllowDangerousSkipPermissions' }
  if ($IAcceptUnattendedRisk) { $args += '-IAcceptUnattendedRisk' }
  if ($AllowModelOnlyFinalCheck) { $args += '-AllowModelOnlyFinalCheck' }
  if ($NoSliceVerifier) { $args += '-NoSliceVerifier' }
  if ($NoWatch) { $args += '-NoWatch' }

  Write-Output 'DISPATCH=launch-showtime.ps1 (serial · one writer · fresh context per slice)'
  & pwsh @args
  exit $LASTEXITCODE
}

# --- ultra / parallel ---
$launch = Join-Path $here 'launch-ultra.ps1'
if (-not (Test-Path -LiteralPath $launch)) {
  throw "Ultra launcher missing: $launch — force serial with -Mode serial"
}
# Cap concurrency for mid-size ledgers (don't spawn 8 bands for 13 slices)
if ($resolvedFrom -like 'auto*') {
  $suggested = [Math]::Max(2, [Math]::Min($MaxConcurrency, [Math]::Ceiling($openSlices / [Math]::Max(1, $BandSize))))
  if ($suggested -lt $MaxConcurrency) {
    Write-Output ("AUTOPRO_MAX_CONCURRENCY_AUTO={0} (was {1})" -f $suggested, $MaxConcurrency)
    $MaxConcurrency = [int]$suggested
  }
}
$args = @(
  '-NoProfile', '-File', $launch,
  '-Root', $Root,
  '-RepoDir', $RepoDir,
  '-BandSize', $BandSize,
  '-MaxConcurrency', $MaxConcurrency,
  '-SplitMode', $SplitMode,
  '-Engine', $Engine,
  '-MaxBandMinutes', $MaxBandMinutes,
  '-StallMinutes', $StallMinutes
)
if ($Model) { $args += @('-Model', $Model) }
if ($AllowOllama) { $args += '-AllowOllama' }
if ($AllowDangerousSkipPermissions) { $args += '-AllowDangerousSkipPermissions' }
if ($IAcceptUnattendedRisk) { $args += '-IAcceptUnattendedRisk' }
if ($NoSliceVerifier) { $args += '-NoSliceVerifier' }
if ($UnblockPaused) { $args += '-UnblockPaused' }
if ($RequireBoard) { $args += '-RequireBoard' }

Write-Output 'DISPATCH=launch-ultra.ps1 (parallel bands · worktrees · capped concurrency)'
& pwsh @args
exit $LASTEXITCODE
