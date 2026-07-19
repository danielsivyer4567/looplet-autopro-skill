#Requires -Version 7.0
<#
  soak-serial-n.ps1 — Serial AutoPro test run: N slices on ONE repo, one runner,
  fresh stub worker process per slice (true serial sub-agent spawns).

  This is NOT 30 concurrent writers. Serial AutoPro = single writer; "30 sub-agents"
  means 30 consecutive clean-context worker processes under one fleet / one lane.

  Default: isolated sandbox under %TEMP% (does not touch product ledger).
  Engine: stub (offline, no LLM tokens). Board + watch optional.

  Usage:
    pwsh -NoProfile -File soak-serial-n.ps1 -Count 30
    pwsh -NoProfile -File soak-serial-n.ps1 -Count 30 -NoBrowser
    pwsh -NoProfile -File soak-serial-n.ps1 -Count 5 -Wait   # block until complete
#>
param(
  [ValidateRange(1, 200)]
  [int]$Count = 30,
  [string]$SandboxRoot = '',
  [switch]$NoBrowser,
  [switch]$NoWatch,
  [switch]$NoShowTime,
  [switch]$Wait,
  [int]$WaitTimeoutMinutes = 45,
  # Keep product autopro alone: always stop stale flags on product if -AlsoStopProduct
  [switch]$AlsoStopProduct
)

$ErrorActionPreference = 'Stop'
$SkillScripts = $PSScriptRoot
$env:AUTOPRO_SOAK = '1'
$env:AUTOPRO_ALLOW_STUB = '1'

. (Join-Path $SkillScripts 'worker-engines.ps1')
. (Join-Path $SkillScripts 'proc-crossos.ps1')

# Preflight stub engine
$stub = Resolve-AutoproEngine -Requested stub -Quiet
if (-not $stub.Available) {
  throw "stub engine unavailable: $($stub.Hint)"
}
Write-Output ("SOAK_ENGINE={0}" -f $stub.Display)

if (-not $SandboxRoot) {
  $SandboxRoot = Join-Path ([IO.Path]::GetTempPath()) ("autopro-soak-serial-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$SandboxRoot = [IO.Path]::GetFullPath($SandboxRoot)
Write-Output ("SOAK_ROOT={0}" -f $SandboxRoot)

if ($AlsoStopProduct) {
  $stop = Join-Path $SkillScripts 'stop-autopro.ps1'
  if (Test-Path -LiteralPath $stop) {
    Write-Output 'Stopping any live autopro on looplet-producer (optional)…'
    & pwsh -NoProfile -File $stop -Root 'C:\repos\looplet-producer' -Quiet 2>&1 |
      ForEach-Object { Write-Output "stop-product> $_" }
  }
}

# Fresh sandbox git repo
if (Test-Path -LiteralPath $SandboxRoot) {
  throw "Sandbox already exists: $SandboxRoot — pick a new path or delete it."
}
New-Item -ItemType Directory -Force -Path $SandboxRoot | Out-Null
Push-Location $SandboxRoot
try {
  git init -b main 2>&1 | Out-Null
  git config user.email 'soak@autopro.local'
  git config user.name 'AutoPro Soak'
  Set-Content -LiteralPath (Join-Path $SandboxRoot 'README.md') -Value "# AutoPro serial soak`nCount=$Count`n" -Encoding utf8
  $scratch = Join-Path $SandboxRoot '.claude/scratch'
  New-Item -ItemType Directory -Force -Path $scratch | Out-Null

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('# Ledger: Serial AutoPro soak · 30-sub-agent spawn test')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('Approved: yes')
  [void]$sb.AppendLine("Mode: serial-soak")
  [void]$sb.AppendLine("SubAgents: $Count (sequential fresh processes · one writer · one repo)")
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('## Goal')
  [void]$sb.AppendLine("Prove serial AutoPro: $Count clean-context worker spawns, one fleet, stub engine, board honesty.")
  [void]$sb.AppendLine('')
  for ($i = 1; $i -le $Count; $i++) {
    $id = 'SC-{0:D2}' -f $i
    [void]$sb.AppendLine("## $id — Soak sub-agent spawn $i of $Count  [pending]")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("- Done when: stub marks this slice done and commits soak-out/$id.txt")
    [void]$sb.AppendLine('')
  }
  [void]$sb.AppendLine('## Out of scope')
  [void]$sb.AppendLine('- Real product code changes')
  [void]$sb.AppendLine('- Concurrent multi-writer on one checkout')
  Set-Content -LiteralPath (Join-Path $scratch 'ledger.md') -Value $sb.ToString() -Encoding utf8

  # Independent final gate (green always for soak)
  $scriptsDir = Join-Path $SandboxRoot 'scripts'
  New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
  @'
#Requires -Version 7.0
Write-Output "FINAL_CHECK_STATUS=green"
Write-Output "FINAL_CHECK_NOTE=serial soak gate · slices complete"
exit 0
'@ | Set-Content -LiteralPath (Join-Path $scriptsDir 'final-check.ps1') -Encoding utf8

  git add -A
  git commit -m "soak: init serial ledger ($Count slices)" 2>&1 | Out-Null
} finally {
  Pop-Location
}

Write-Output ("SOAK_LEDGER={0}" -f (Join-Path $SandboxRoot '.claude/scratch/ledger.md'))
Write-Output ("SOAK_SLICES={0}" -f $Count)

# Clean any leftover global soak sessions is N/A — new session ids every arm

$launch = Join-Path $SkillScripts 'launch-showtime.ps1'
$launchArgs = @(
  '-NoProfile', '-File', $launch,
  '-Root', $SandboxRoot,
  '-RepoDir', $SandboxRoot,
  '-Engine', 'stub',
  '-AllowDangerousSkipPermissions',
  '-IAcceptUnattendedRisk',
  '-NoSliceVerifier',
  '-MaxSliceMinutes', '5'
)
if ($NoBrowser) { $launchArgs += '-NoBrowser' }
if ($NoWatch) { $launchArgs += '-NoWatch' }
if ($NoShowTime) { $launchArgs += '-NoShowTime' }

Write-Output 'Arming serial AutoPro soak…'
$out = & pwsh @launchArgs 2>&1
$out | ForEach-Object { Write-Output $_ }
$joined = ($out | ForEach-Object { "$_" }) -join "`n"

$sessionId = ''
$runnerPid = 0
$boardUrl = ''
if ($joined -match 'SHOWTIME_SESSION=(\S+)') { $sessionId = $Matches[1] }
if ($joined -match 'RUNNER_PID=(\d+)') { $runnerPid = [int]$Matches[1] }
if ($joined -match 'SHOWTIME_URL=(\S+)') { $boardUrl = $Matches[1] }

Write-Output ''
Write-Output '======== SERIAL SOAK ARMED ========'
Write-Output ("slices     = {0} (one fresh stub worker each)" -f $Count)
Write-Output ("sandbox    = {0}" -f $SandboxRoot)
Write-Output ("session    = {0}" -f $sessionId)
Write-Output ("runnerPid  = {0}" -f $runnerPid)
Write-Output ("board      = {0}" -f $(if ($boardUrl) { $boardUrl } else { '(NoShowTime)' }))
Write-Output ("log        = {0}" -f (Join-Path $SandboxRoot '.claude/scratch/autopro.log'))
Write-Output ("needs-you  = {0}" -f (Join-Path $SandboxRoot '.claude/scratch/AUTOPRO-NEEDS-YOU.md'))
Write-Output '==================================='
Write-Output ''
Write-Output 'Serial contract: ONE writer, ONE live coding worker at a time,'
Write-Output "but $Count sequential sub-agent spawns (clean context each)."
Write-Output 'Watch board + autopro.log. Not concurrent multi-agent on one tree.'

if (-not $Wait) {
  Write-Output ''
  Write-Output 'Tip: re-run with -Wait to block until complete/disarmed.'
  exit 0
}

# Wait for disarm / complete
$deadline = (Get-Date).AddMinutes($WaitTimeoutMinutes)
$log = Join-Path $SandboxRoot '.claude/scratch/autopro.log'
$ledger = Join-Path $SandboxRoot '.claude/scratch/ledger.md'
Write-Output ("Waiting up to {0}m for complete…" -f $WaitTimeoutMinutes)

$sessionStatePath = Join-Path $SandboxRoot '.claude/scratch/autopro-session.json'
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 2
  $flags = @(Get-ChildItem -Path (Join-Path $SandboxRoot '.claude/scratch/autopro-on*') -File -ErrorAction SilentlyContinue)
  $done = 0
  $pending = 0
  if (Test-Path -LiteralPath $ledger) {
    $t = Get-Content -LiteralPath $ledger -Raw
    $done = ([regex]::Matches($t, '(?m)^##\s+SC-\d+[^\n]*\[done\]')).Count
    $pending = ([regex]::Matches($t, '(?m)^##\s+SC-\d+[^\n]*\[pending\]')).Count
  }
  $runnerAlive = $false
  if ($runnerPid -gt 0) {
    try { Get-Process -Id $runnerPid -ErrorAction Stop | Out-Null; $runnerAlive = $true } catch { $runnerAlive = $false }
  }
  $state = ''
  $outcome = ''
  if (Test-Path -LiteralPath $sessionStatePath) {
    try {
      $st = Get-Content -LiteralPath $sessionStatePath -Raw | ConvertFrom-Json
      $state = [string]$st.state
      $outcome = [string]$st.outcome
    } catch {}
  }
  Write-Output ("  progress done={0}/{1} pending={2} flags={3} runnerAlive={4} state={5} outcome={6}" -f $done, $Count, $pending, $flags.Count, $runnerAlive, $state, $outcome)

  # Green: complete outcome OR all slices done + no flag + runner gone
  if ($outcome -eq 'complete' -or $state -eq 'complete') {
    Write-Output 'SOAK_RESULT=green'
    Write-Output ("SOAK_DONE={0}" -f $done)
    if (Test-Path -LiteralPath (Join-Path $SandboxRoot '.claude/scratch/SHOWTIME-HANDOVER.md')) {
      Write-Output ("HANDOVER={0}" -f (Join-Path $SandboxRoot '.claude/scratch/SHOWTIME-HANDOVER.md'))
    }
    exit 0
  }
  # Red terminal outcomes (finalizer failed cleanly)
  if ($outcome -match 'final-check|gate-failed|blocked|zero-progress|slice-' -and -not $runnerAlive) {
    Write-Output ("SOAK_RESULT=red outcome={0}" -f $outcome)
    if (Test-Path -LiteralPath $log) {
      Get-Content -LiteralPath $log -Tail 40 | ForEach-Object { Write-Output "log> $_" }
    }
    exit 1
  }
  if ($flags.Count -eq 0 -and -not $runnerAlive) {
    if ($done -ge $Count) {
      # Runner died after slices without writing complete — treat as red hang
      if ($outcome -eq 'complete') {
        Write-Output 'SOAK_RESULT=green'
        exit 0
      }
      Write-Output ("SOAK_RESULT=red done={0} expected={1} outcome={2} (disarmed without complete — see log)" -f $done, $Count, $outcome)
      if (Test-Path -LiteralPath $log) {
        Get-Content -LiteralPath $log -Tail 40 | ForEach-Object { Write-Output "log> $_" }
      }
      exit 1
    }
    Write-Output ("SOAK_RESULT=red done={0} expected={1} (disarmed early — see log)" -f $done, $Count)
    if (Test-Path -LiteralPath $log) {
      Get-Content -LiteralPath $log -Tail 40 | ForEach-Object { Write-Output "log> $_" }
    }
    exit 1
  }
}

Write-Output 'SOAK_RESULT=timeout'
if (Test-Path -LiteralPath $log) {
  Get-Content -LiteralPath $log -Tail 60 | ForEach-Object { Write-Output "log> $_" }
}
exit 2
