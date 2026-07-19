# test-ultra-p0-p2.ps1 — offline unit checks for P0–P2 (no live arm)
#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'ultra-band-lib.ps1')
. (Join-Path $here 'showtime-board-gate.ps1')
. (Join-Path $here 'worker-engines.ps1')

$fail = 0
function Assert-True($cond, $msg) {
  if (-not $cond) { Write-Host "FAIL: $msg" -ForegroundColor Red; $script:fail++ }
  else { Write-Host "OK: $msg" -ForegroundColor Green }
}

# --- band math ---
$e = @(Get-EvenBandSizes -N 7 -S 5)
Assert-True (($e -join ',') -eq '4,3') 'even 7/5 → 4,3'
$e2 = @(Get-EvenBandSizes -N 44 -S 5)
Assert-True (($e2 | Measure-Object -Sum).Sum -eq 44) 'even 44/5 sums to 44'
$p = @(Get-PackBandSizes -N 7 -S 5)
Assert-True (($p -join ',') -eq '5,2') 'pack 7/5 → 5,2'
$ids = 1..10 | ForEach-Object { 'SC-{0:D2}' -f $_ }
$plan = @(Get-UltraBandPlan -ScIds $ids -BandSize 5 -SplitMode even)
Assert-True ($plan.Count -eq 2) 'plan 10/5 → 2 bands'
Assert-True ($plan[0].BandId -eq 'B01') 'first band B01'
$starts = Get-StartsAfterLabel -BandIndex 3 -MaxConcurrency 3 -Bands $plan
# only 2 bands in plan — index 3 out of range uses generic
Assert-True ($null -ne (Get-StartsAfterLabel -BandIndex 1 -MaxConcurrency 1 -Bands $plan)) 'startsAfter for queued band'

# --- starts after free-slot ---
$big = @(Get-UltraBandPlan -ScIds @(1..15 | ForEach-Object { "SC-$_" }) -BandSize 5)
$lab = Get-StartsAfterLabel -BandIndex 3 -MaxConcurrency 3 -Bands $big
Assert-True ($lab -match 'B01') 'B04 starts after B01 when C=3'

# --- engine matrix present ---
$all = Get-AllEngineResolutions
Assert-True ($all.Count -ge 4) 'engine resolutions listed'
$autoOk = $false
try { $null = Resolve-AutoproEngine -Requested auto -Quiet; $autoOk = $true } catch {}
Assert-True $autoOk 'at least one engine resolves for auto'

# --- board helpers load ---
Assert-True ((Get-Command Test-BoardSessionPresent) -ne $null) 'Test-BoardSessionPresent exported'
Assert-True ((Get-Command Assert-BoardSessionRegistered) -ne $null) 'Assert-BoardSessionRegistered exported'
Assert-True ((Get-Command Ensure-BoardJoinApproved) -ne $null) 'Ensure-BoardJoinApproved exported'

# --- band-result validation logic (inline copy of rule) ---
function Test-Result($obj) {
  if (-not $obj) { return $false }
  if ($obj.PSObject.Properties.Name -contains 'ok') { return [bool]$obj.ok }
  if ($obj.done) { return $true }
  return $false
}
Assert-True (Test-Result ([pscustomobject]@{ ok = $true; bandId = 'B01' })) 'result ok:true'
Assert-True (-not (Test-Result ([pscustomobject]@{ ok = $false }))) 'result ok:false'
Assert-True (Test-Result ([pscustomobject]@{ done = @('SC-07') })) 'result done array'
Assert-True (-not (Test-Result $null)) 'result null'

# --- worker launcher generation ---
# A worker root can contain spaces. Start-Process flattens an ArgumentList array
# on Windows, so the generated -File path must be quoted as one command-line
# argument. The permission flag must also be expanded while generating the
# worker script (rather than left as an undefined runtime variable).
$ultraSource = Get-Content -LiteralPath (Join-Path $here 'autopro-ultra.ps1') -Raw
$resumeSource = Get-Content -LiteralPath (Join-Path $here 'ultra-resume.ps1') -Raw
Assert-True ($ultraSource.Contains('-ArgumentList $argLine')) 'ultra worker launcher uses a quoted argument line'
Assert-True ($resumeSource.Contains('-ArgumentList $argLine')) 'ultra resume launcher uses a quoted argument line'
Assert-True ($ultraSource.Contains('-SkipPermissions:$skipLit')) 'ultra worker expands the requested permission flag'
Assert-True (-not $ultraSource.Contains('-SkipPermissions:`$skipLit')) 'ultra worker does not leave an undefined permission variable'

# --- master-ledger single-writer race fix (CRITICAL) ---
# Band workers must NOT be told to write the shared master ledger; the sole
# orchestrator reconciles master from band-result.json. This is the fix for N
# concurrent engine processes doing unsynchronized RMW on the of-record file.
Assert-True (-not ($ultraSource -match 'THIS ledger AND master')) 'ultra band prompt does not tell workers to write master'
Assert-True (-not ($resumeSource -match 'THIS ledger AND master')) 'resume band prompt does not tell workers to write master'
Assert-True ($ultraSource.Contains('Get-BandDoneScIds')) 'ultra orchestrator reconciles master from band results'
Assert-True ($resumeSource.Contains('Get-BandDoneScIds')) 'resume orchestrator reconciles master from band results'
$libSource = Get-Content -LiteralPath (Join-Path $here 'ultra-band-lib.ps1') -Raw
Assert-True ($libSource -match '\[System\.IO\.File\]::Move\(\$tmp') 'Set-LedgerSliceStates writes atomically (temp + rename)'

# --- canonical Test-BandResultOk / Get-BandDoneScIds (shared, fail-closed) ---
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('ultra-test-' + [guid]::NewGuid().ToString('N'))
$tmpScratch = Join-Path $tmpRoot '.claude/scratch'
New-Item -ItemType Directory -Force -Path $tmpScratch | Out-Null
try {
  $brPath = Join-Path $tmpScratch 'band-result.json'
  '{"ok":true,"bandId":"B01","done":["SC-01","SC-02"]}' | Set-Content -LiteralPath $brPath -Encoding utf8
  Assert-True (Test-BandResultOk -Worktree $tmpRoot -BandId 'B01') 'Test-BandResultOk: ok:true → done'
  Assert-True (-not (Test-BandResultOk -Worktree $tmpRoot -BandId 'B99')) 'Test-BandResultOk: wrong bandId → not done'
  '{"ok":"false","bandId":"B01"}' | Set-Content -LiteralPath $brPath -Encoding utf8
  Assert-True (-not (Test-BandResultOk -Worktree $tmpRoot -BandId 'B01')) 'Test-BandResultOk: string "false" fails closed (not [bool]$true)'
  '{"ok":true,"bandId":"B01","done":["SC-01","SC-02","SC-99"]}' | Set-Content -LiteralPath $brPath -Encoding utf8
  $doneIds = @(Get-BandDoneScIds -Worktree $tmpRoot -ClaimedScIds @('SC-01', 'SC-02'))
  Assert-True (($doneIds -join ',') -eq 'SC-01,SC-02') 'Get-BandDoneScIds returns only CLAIMED SCs (drops unclaimed SC-99)'

  $tmpLedger = Join-Path $tmpScratch 'ledger.md'
  "# Ledger`n`n## SC-01 — first [pending]`n## SC-02 — second [pending]`n" | Set-Content -LiteralPath $tmpLedger -Encoding utf8
  Set-LedgerSliceStates -LedgerPath $tmpLedger -IdToState @{ 'SC-01' = 'done' }
  $afterLedger = Get-Content -LiteralPath $tmpLedger -Raw
  Assert-True ($afterLedger -match '## SC-01 — first\s+\[done\]') 'Set-LedgerSliceStates marks the target SC done'
  Assert-True ($afterLedger -match '## SC-02 — second\s+\[pending\]') 'Set-LedgerSliceStates leaves other SCs untouched'
  Assert-True (-not (Test-Path -LiteralPath ("$tmpLedger.tmp.$PID"))) 'Set-LedgerSliceStates leaves no temp file (atomic rename)'
} finally {
  Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- remaining ultra hardening (gate / stall / stop / lifecycle) ---
$stopSrc = Get-Content -LiteralPath (Join-Path $here 'stop-autopro.ps1') -Raw
$launchUltraSrc = Get-Content -LiteralPath (Join-Path $here 'launch-ultra.ps1') -Raw

# Independent per-band gate — 'done' is no longer pure self-attestation.
Assert-True ($ultraSource.Contains('Invoke-BandGate')) 'ultra: independent per-band gate wired'
Assert-True ($ultraSource.Contains('Resolve-IndependentFinalGate')) 'ultra: reuses the serial independent gate resolver'
Assert-True ($ultraSource.Contains('done-without-commit')) 'ultra: band done requires a real commit past baseSha'
Assert-True ($resumeSource.Contains('Resolve-IndependentFinalGate') -and $resumeSource.Contains('no commit past baseSha')) 'resume: re-verifies done (commit + gate), never trusts persisted ok:true'

# Kill hardening.
Assert-True (-not $ultraSource.Contains('Stop-Process -Id $wPid -Force')) 'ultra: timeout no longer uses bare Stop-Process (would orphan the engine subtree)'
Assert-True ($ultraSource.Contains('Clear-BandIndexLock')) 'ultra: clears a stale index.lock after a tree kill'
Assert-True ($ultraSource.Contains('Test-BandWorkerAlive')) 'ultra: liveness/kill verify pid identity (no recycled-pid kill)'

# Stop completeness — ultra fleets actually stop.
Assert-True ($stopSrc.Contains('ultra-orchestrator.pid')) 'stop: reads ultra-orchestrator.pid'
Assert-True ($stopSrc.Contains('KILL_ULTRA_BAND')) 'stop: kills recorded band worker pids'
Assert-True ($stopSrc.Contains('autopro-ultra\.ps1|ultra-resume\.ps1')) 'stop: runner match includes the ultra orchestrators'
Assert-True ($stopSrc.Contains("autopro-on.ultra")) 'stop: keeps autopro-on.ultra regardless of -SessionId'

# Singleton lease + collision-proof runId + gitignore + prune.
Assert-True ($launchUltraSrc.Contains('already armed on this root')) 'launch-ultra: singleton lease refuses a second armed orchestrator'
Assert-True ($ultraSource.Contains('yyyyMMddHHmmssfff')) 'ultra: runId is millisecond+PID unique (no same-second worktree clobber)'
Assert-True ($ultraSource.Contains('.worktrees-ultra/')) 'ultra: asserts .worktrees-ultra into .gitignore'
Assert-True ($ultraSource.Contains('git worktree prune')) 'ultra: prunes stale worktree admin entries at start'

# Runnable-SC dedup + alpha-id unblock (functional).
$tmp2 = Join-Path ([System.IO.Path]::GetTempPath()) ('ultra-test2-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp2 | Out-Null
try {
  $dup = Join-Path $tmp2 'ledger.md'
  "# L`n`n## SC-01 — a [pending]`n## SC-02 — b [pending]`n## SC-01 — a-dup [pending]`n## SC-DRY-01 — c [blocked]`n" | Set-Content -LiteralPath $dup -Encoding utf8
  $runnable2 = @(Get-RunnableScIds -LedgerPath $dup)
  Assert-True ((@($runnable2 | Where-Object { $_ -eq 'SC-01' }).Count) -eq 1) 'Get-RunnableScIds dedups a duplicated SC id (one id -> one band)'
  Set-LedgerUnblockAllBlocked -LedgerPath $dup
  $unblocked = Get-Content -LiteralPath $dup -Raw
  Assert-True ($unblocked -match '## SC-DRY-01 — c\s+\[pending\]') 'Set-LedgerUnblockAllBlocked unblocks alpha/suffixed ids (SC-DRY-01)'
} finally {
  Remove-Item -LiteralPath $tmp2 -Recurse -Force -ErrorAction SilentlyContinue
}

# --- live board optional soft check ---
try {
  $base = Get-BoardBaseUrl
  if ($base) {
    $h = Invoke-BoardApi -Method GET -Path '/api/health'
    Assert-True ($h.ok -eq $true) 'live board health ok'
  } else {
    Write-Host 'SKIP: board not running (ok for offline CI)' -ForegroundColor Yellow
  }
} catch {
  Write-Host "SKIP: board probe $($_.Exception.Message)" -ForegroundColor Yellow
}

if ($fail -gt 0) {
  Write-Host "FAILED $fail checks" -ForegroundColor Red
  exit 1
}
Write-Host 'ALL P0-P2 offline checks passed' -ForegroundColor Green
exit 0
