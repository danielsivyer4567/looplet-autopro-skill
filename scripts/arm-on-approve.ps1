<#
  arm-on-approve.ps1 — Door A → Door B bridge (Looplet Show Time).

  Called after the operator APPROVES a join request on the board.
  Approve alone only puts a lane on the TV. This script ARMS autopro
  in the target repo so workers actually run.

  Fallbacks (in order):
    1) launch-showtime.ps1 with risk switches (full arm + board heartbeat)
    2) If already live runner for this Root → report already_armed + pid
    3) If ledger not Approved:yes → skip
    4) Launch fail on gate → retry -AllowModelOnlyFinalCheck once
    5) Log everything to <Root>\.claude\scratch\arm-on-approve.log

  Exit codes:
    0 = armed or already armed or -WhatIf ok
    2 = skipped (not armable)
    3 = failed

  -WhatIf : validate only (no launch) — for offline SC-R02 proof
#>
param(
  [Parameter(Mandatory = $true)][string]$RepoDir,
  [string]$Root = '',
  [string]$SessionId = '',
  [string]$Engine = 'auto',
  [string]$Model = '',
  [switch]$NoBrowser,
  [switch]$ForceModelOnly,
  # Board approve IS operator consent for unattended arm in this product.
  [switch]$IAcceptBoardApproveAsArmConsent,
  # Offline / CI: validate gates only, never launch
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$SkillScripts = $PSScriptRoot
$Launch = Join-Path $SkillScripts 'launch-showtime.ps1'

# --- pure helpers (also exercised by test-arm-on-approve.ps1) ---

function Test-LedgerApprovedText([string]$raw) {
  return [bool]([regex]::IsMatch([string]$raw, '(?im)^Approved:\s*yes'))
}

function Test-JunkSessionId([string]$sessionId) {
  if ([string]::IsNullOrWhiteSpace($sessionId)) { return $false }
  return [bool]($sessionId -match '^(sound-test|alert-test|LOUD-|HEAR-ME|BLAST-|SOUND|alarm|prove-grok)')
}

function Test-JunkLedgerTitle([string]$title) {
  if ([string]::IsNullOrWhiteSpace($title)) { return $false }
  return [bool]($title -match '(?i)(SOUND TEST|LOUD ALARM|HEAR THIS|BLAST SOUND|TEST LOUD JOIN|alarm proof)')
}

function Get-ArmParseFromLaunchOutput([string[]]$lines) {
  $armedSid = ''
  $runnerPid = 0
  foreach ($line in $lines) {
    $s = [string]$line
    # launch-showtime + our own ARM_* lines
    if ($s -match 'SHOWTIME_SESSION=(\S+)') { $armedSid = $Matches[1].Trim() }
    if ($s -match 'ARM_RUNNER_SESSION=(\S+)') { $armedSid = $Matches[1].Trim() }
    if ($s -match 'ARM_SESSION=(\S+)') { $armedSid = $Matches[1].Trim() }
    if ($s -match '(?i)(?<!JOIN_|ARM_JOIN_)SESSION_ID=(\S+)') { $armedSid = $Matches[1].Trim() }
    if ($s -match '(?i)(?<!JOIN_)sessionId=(\S+)') {
      $cand = $Matches[1].Trim()
      if ($cand -match '^sess_') { $armedSid = $cand }
    }
    if ($s -match 'RUNNER_PID=(\d+)') { $runnerPid = [int]$Matches[1] }
    if ($s -match 'ARM_PID=(\d+)') { $runnerPid = [int]$Matches[1] }
    if ($s -match '(?i)runnerPid=(\d+)') { $runnerPid = [int]$Matches[1] }
    if ($s -match 'LIVE_RUNNER_PID=(\d+)') { $runnerPid = [int]$Matches[1] }
  }
  return [pscustomobject]@{ ArmedSessionId = $armedSid; RunnerPid = $runnerPid }
}

# Export helpers for dot-sourcing tests
if ($WhatIf -and $RepoDir -eq '__helpers_only__') {
  # test harness loads functions only
  return
}

$RepoDir = (Resolve-Path -LiteralPath $RepoDir).Path
if (-not $Root) { $Root = $RepoDir }
$scratch = Join-Path $Root '.claude\scratch'
$ledger = Join-Path $RepoDir '.claude\scratch\ledger.md'
$log = Join-Path $scratch 'arm-on-approve.log'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null

function Log([string]$m) {
  $line = '{0} {1}' -f (Get-Date -Format o), $m
  try { Add-Content -LiteralPath $log -Value $line -Encoding utf8 } catch {}
  Write-Output $line
}

function Get-LiveRunnerPids([string]$rootPath) {
  @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" `
      -OperationTimeoutSec 8 -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and
      $_.CommandLine -match 'autopro-runner\.ps1' -and
      $_.CommandLine -like "*$rootPath*"
    } | ForEach-Object { $_.ProcessId })
}

Log "arm-on-approve start RepoDir=$RepoDir Root=$Root SessionId=$SessionId Engine=$Engine WhatIf=$WhatIf"

if (-not $IAcceptBoardApproveAsArmConsent -and -not $WhatIf) {
  Log 'REFUSE: pass -IAcceptBoardApproveAsArmConsent (board Approve is the human gate)'
  Write-Output 'ARM_STATUS=skipped'
  Write-Output 'ARM_REASON=no_consent_flag'
  exit 2
}

if (-not (Test-Path -LiteralPath $ledger)) {
  Log "SKIP no ledger at $ledger"
  Write-Output 'ARM_STATUS=skipped'
  Write-Output 'ARM_REASON=no_ledger'
  exit 2
}

$raw = Get-Content -LiteralPath $ledger -Raw
if (-not (Test-LedgerApprovedText $raw)) {
  Log 'SKIP ledger not Approved: yes'
  Write-Output 'ARM_STATUS=skipped'
  Write-Output 'ARM_REASON=ledger_not_approved'
  exit 2
}
Write-Output 'ARM_LEDGER_APPROVED=1'

if (Test-JunkSessionId $SessionId) {
  Log "SKIP junk sessionId=$SessionId"
  Write-Output 'ARM_STATUS=skipped'
  Write-Output 'ARM_REASON=junk_session'
  exit 2
}

if ($SessionId) {
  Write-Output ("ARM_JOIN_SESSION={0}" -f $SessionId)
}

# WhatIf stops after pure validation — never launch, never query runners
if ($WhatIf) {
  Log 'WhatIf: validation ok — would launch launch-showtime.ps1 (no arm performed)'
  Write-Output 'ARM_STATUS=whatif_ok'
  Write-Output 'ARM_REASON=dry_run'
  Write-Output ("ARM_WOULD_LAUNCH={0}" -f $Launch)
  exit 0
}

$live = Get-LiveRunnerPids $Root
if ($live.Count -gt 0) {
  Log ("ALREADY armed live pids=" + ($live -join ','))
  Write-Output 'ARM_STATUS=already_armed'
  Write-Output ("ARM_PID={0}" -f $live[0])
  Write-Output ("ARM_PIDS={0}" -f ($live -join ','))
  if ($SessionId) { Write-Output ("ARM_JOIN_SESSION={0}" -f $SessionId) }
  exit 0
}

if (-not (Test-Path -LiteralPath $Launch)) {
  Log "FAIL launch-showtime.ps1 missing at $Launch"
  Write-Output 'ARM_STATUS=failed'
  Write-Output 'ARM_REASON=no_launch_script'
  exit 3
}

$launchArgs = @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass',
  '-File', $Launch,
  '-Root', $Root,
  '-RepoDir', $RepoDir,
  '-Engine', $Engine,
  '-AllowDangerousSkipPermissions',
  '-IAcceptUnattendedRisk',
  '-NoBrowser'
)
if ($Model) { $launchArgs += @('-Model', $Model) }
if ($ForceModelOnly) { $launchArgs += '-AllowModelOnlyFinalCheck' }

function Invoke-Launch([string[]]$la) {
  Log ("launch> pwsh " + ($la -join ' '))
  $out = & pwsh.exe @la 2>&1 | ForEach-Object { "$_" }
  foreach ($line in $out) { Log "launch: $line"; Write-Output $line }
  return @($out)
}

function Resolve-ArmResult([string[]]$out) {
  $parsed = Get-ArmParseFromLaunchOutput $out
  $armedSid = [string]$parsed.ArmedSessionId
  $runnerPid = [int]$parsed.RunnerPid

  Start-Sleep -Seconds 3
  $live2 = Get-LiveRunnerPids $Root
  if ($live2.Count -gt 0) { $runnerPid = [int]$live2[0] }

  if ($SessionId) { Write-Output ("ARM_JOIN_SESSION={0}" -f $SessionId) }

  if ($runnerPid -gt 0 -or $live2.Count -gt 0) {
    Write-Output 'ARM_STATUS=armed'
    if ($runnerPid -gt 0) { Write-Output ("ARM_PID={0}" -f $runnerPid) }
    if ($armedSid) {
      Write-Output ("ARM_SESSION={0}" -f $armedSid)
      Write-Output ("ARM_RUNNER_SESSION={0}" -f $armedSid)
    }
    Log "SUCCESS armed pid=$runnerPid session=$armedSid join=$SessionId"
    return $true
  }

  $flags = @(Get-ChildItem -Path (Join-Path $scratch 'autopro-on*') -File -ErrorAction SilentlyContinue)
  if ($flags.Count) {
    Write-Output 'ARM_STATUS=armed_flag_only'
    Write-Output ("ARM_FLAG={0}" -f $flags[0].Name)
    if ($armedSid) {
      Write-Output ("ARM_SESSION={0}" -f $armedSid)
      Write-Output ("ARM_RUNNER_SESSION={0}" -f $armedSid)
    }
    Log "ARMED flag present but runner pid not seen yet: $($flags[0].Name) session=$armedSid"
    return $true
  }
  return $false
}

try {
  $out = Invoke-Launch $launchArgs
  if (Resolve-ArmResult $out) { exit 0 }

  Log 'FAIL launch finished but no runner/flag — retry with AllowModelOnlyFinalCheck'
  $retryArgs = $launchArgs + @('-AllowModelOnlyFinalCheck')
  $out2 = Invoke-Launch $retryArgs
  if (Resolve-ArmResult $out2) {
    Write-Output 'ARM_NOTE=model_only_fallback'
    exit 0
  }

  Log 'FAIL both launch attempts'
  Write-Output 'ARM_STATUS=failed'
  Write-Output 'ARM_REASON=no_runner_after_launch'
  exit 3
} catch {
  $msg = [string]$_.Exception.Message
  Log ("FAIL launch exception: " + $msg)
  Write-Output 'ARM_STATUS=failed'
  $short = ($msg -replace '\s+', ' ')
  if ($short.Length -gt 200) { $short = $short.Substring(0, 200) }
  Write-Output ("ARM_REASON={0}" -f $short)
  exit 3
}
