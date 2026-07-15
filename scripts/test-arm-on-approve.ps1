<#
  test-arm-on-approve.ps1 — offline unit checks for Door A→B (no Show Time, no arm).
  Exit 0 = all green.
#>
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$arm = Join-Path $here 'arm-on-approve.ps1'
$fail = 0

function Assert-True($cond, $msg) {
  if (-not $cond) {
    Write-Host "FAIL: $msg" -ForegroundColor Red
    $script:fail++
  } else {
    Write-Host "ok: $msg"
  }
}

# Dot-source helpers by loading function definitions from the script file
# (parse the functions without executing the main path).
$src = Get-Content -LiteralPath $arm -Raw
# Evaluate only the helper function blocks we need
Invoke-Expression @'
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
    if ($s -match 'SHOWTIME_SESSION=(\S+)') { $armedSid = $Matches[1].Trim() }
    if ($s -match 'ARM_RUNNER_SESSION=(\S+)') { $armedSid = $Matches[1].Trim() }
    if ($s -match 'ARM_SESSION=(\S+)') { $armedSid = $Matches[1].Trim() }
    if ($s -match 'RUNNER_PID=(\d+)') { $runnerPid = [int]$Matches[1] }
    if ($s -match 'ARM_PID=(\d+)') { $runnerPid = [int]$Matches[1] }
    if ($s -match 'LIVE_RUNNER_PID=(\d+)') { $runnerPid = [int]$Matches[1] }
  }
  return [pscustomobject]@{ ArmedSessionId = $armedSid; RunnerPid = $runnerPid }
}
'@

# --- pure unit checks ---
Assert-True (Test-LedgerApprovedText "Approved: yes @ 2026-07-15`n") 'Approved: yes detected'
Assert-True (Test-LedgerApprovedText "Approved: yes") 'Approved: yes bare'
Assert-True (-not (Test-LedgerApprovedText "Approved: pending`n")) 'pending not approved'
Assert-True (-not (Test-LedgerApprovedText "Approved: no`n")) 'no not approved'
Assert-True (-not (Test-LedgerApprovedText "")) 'empty not approved'

Assert-True (Test-JunkSessionId 'sound-test-1') 'junk sound-test'
Assert-True (Test-JunkSessionId 'LOUD-141421') 'junk LOUD-'
Assert-True (Test-JunkSessionId 'BLAST-foo') 'junk BLAST-'
Assert-True (Test-JunkSessionId 'prove-grok-140147') 'junk prove-grok'
Assert-True (-not (Test-JunkSessionId 'sess_armproof_abc')) 'real sess_ ok'
Assert-True (-not (Test-JunkSessionId 'producer-main-1')) 'producer-main ok'

Assert-True (Test-JunkLedgerTitle 'SOUND TEST — you should hear ALARMS') 'junk title sound'
Assert-True (-not (Test-JunkLedgerTitle 'OTIS LIVE remaining (extension)')) 'real title ok'

$parsed = Get-ArmParseFromLaunchOutput @(
  'SHOWTIME_SESSION=sess_47db19ef9849',
  'RUNNER_PID=58608',
  'ENGINE=claude'
)
Assert-True ($parsed.ArmedSessionId -eq 'sess_47db19ef9849') 'parse SHOWTIME_SESSION'
Assert-True ($parsed.RunnerPid -eq 58608) 'parse RUNNER_PID'

$parsed2 = Get-ArmParseFromLaunchOutput @('ARM_SESSION=sess_x', 'ARM_PID=12')
Assert-True ($parsed2.ArmedSessionId -eq 'sess_x') 'parse ARM_SESSION'
Assert-True ($parsed2.RunnerPid -eq 12) 'parse ARM_PID'

# --- WhatIf dry-run against a self-contained approved fixture (no foreign repo) ---
# SC-06: earlier this pointed at C:\LOOPLET\ai-sidebar, whose ledger became a
# pointer (not Approved: yes). The offline proof must not depend on any other
# repo's approval state — build a throwaway approved ledger in TEMP instead.
$fixRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("armfix_$PID`_" + [guid]::NewGuid().ToString('N'))
$fixScratch = Join-Path $fixRepo '.claude\scratch'
New-Item -ItemType Directory -Force -Path $fixScratch | Out-Null
Set-Content -LiteralPath (Join-Path $fixScratch 'ledger.md') `
  -Value "# Arm fixture ledger`nApproved: yes @ 2026-07-15`n`n## S1 fixture slice  [pending]`n" `
  -Encoding utf8
try {
  $out = & pwsh -NoProfile -File $arm -RepoDir $fixRepo -Root $fixRepo -SessionId 'sess_whatif_test' -WhatIf 2>&1 | ForEach-Object { "$_" }
  $joined = $out -join "`n"
  Assert-True ($LASTEXITCODE -eq 0) "WhatIf exit 0 (got $LASTEXITCODE)"
  Assert-True ($joined -match 'ARM_STATUS=whatif_ok') 'WhatIf emits whatif_ok'
  Assert-True ($joined -match 'ARM_LEDGER_APPROVED=1') 'WhatIf sees approved ledger'

  # --- WhatIf junk session must skip before launch ---
  $outJ = & pwsh -NoProfile -File $arm -RepoDir $fixRepo -Root $fixRepo -SessionId 'sound-test-xyz' -WhatIf -IAcceptBoardApproveAsArmConsent 2>&1 | ForEach-Object { "$_" }
  $j = $outJ -join "`n"
  Assert-True ($LASTEXITCODE -eq 2) "junk WhatIf exit 2 (got $LASTEXITCODE)"
  Assert-True ($j -match 'ARM_REASON=junk_session') 'junk session skipped'
} finally {
  Remove-Item -LiteralPath $fixRepo -Recurse -Force -ErrorAction SilentlyContinue
}

# theater-server source still has the bridge
$server = Join-Path $here 'theater-server.mjs'
$srv = Get-Content -LiteralPath $server -Raw
Assert-True ($srv -match 'tryAutoArmAfterApprove') 'server has tryAutoArmAfterApprove'
Assert-True ($srv -match 'armRunnerSessionId') 'server maps armRunnerSessionId'
Assert-True ($srv -match 'purgeJunkSessions') 'server has purgeJunkSessions'

if ($fail -gt 0) {
  Write-Host "FAILED $fail assertion(s)" -ForegroundColor Red
  exit 1
}
Write-Host 'ALL OK — test-arm-on-approve offline green'
exit 0
