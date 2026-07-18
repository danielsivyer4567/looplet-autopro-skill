<#
  test-autopro-reliability.ps1 — pure unit/smoke checks for autopro reliability.

  No live Claude tokens. No production. Exit 0 = all pass.
#>
$ErrorActionPreference = 'Stop'
$failed = 0
function Ok($m) { Write-Output "PASS  $m" }
function Bad($m) { Write-Output "FAIL  $m"; $script:failed++ }

$Scripts = $PSScriptRoot
Write-Output '==== Autopro reliability tests ===='

# ---- parse all critical scripts ---------------------------------------------
foreach ($name in @(
    'autopro-runner.ps1',
    'launch-showtime.ps1',
    'autopro-status.ps1',
    'stop-autopro.ps1',
    'worker-engines.ps1',
    'autopro-doctor.ps1',
    'smoke-worker-engines.ps1'
  )) {
  $path = Join-Path $Scripts $name
  if (-not (Test-Path -LiteralPath $path)) { Bad "parse: missing $name"; continue }
  $errs = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count) { Bad "parse: $name — $($errs[0].Message)" } else { Ok "parse: $name" }
}

$runnerSrc = Get-Content -LiteralPath (Join-Path $Scripts 'autopro-runner.ps1') -Raw
$launchSrc = Get-Content -LiteralPath (Join-Path $Scripts 'launch-showtime.ps1') -Raw
$statusSrc = Get-Content -LiteralPath (Join-Path $Scripts 'autopro-status.ps1') -Raw

# ---- P1-T1: multi-engine worker resolve + argv fail-fast ---------------------
if ($runnerSrc -match 'worker-engines\.ps1') { Ok 'exe: dotsources worker-engines' } else { Bad 'exe: worker-engines not dotted' }
if ($runnerSrc -match 'function Invoke-WorkerProcess') { Ok 'exe: Invoke-WorkerProcess present' } else { Bad 'exe: Invoke-WorkerProcess missing' }
if ($runnerSrc -match 'Resolve-AutoproEngine') { Ok 'exe: Resolve-AutoproEngine used' } else { Bad 'exe: Resolve-AutoproEngine missing' }
if ($runnerSrc -match "unknown option\s+\\?'?-" -or $runnerSrc -match 'unknown option') {
  Ok 'exe: unknown option fail-fast wired'
} else { Bad 'exe: unknown option fail-fast missing' }
if ($runnerSrc -match 'worker-argv-parse-failed' -or $runnerSrc -match 'claude-argv-parse-failed') {
  Ok 'exe: argv outcome blocked state'
} else { Bad 'exe: argv blocked outcome missing' }
if ($runnerSrc -match 'MaxSliceMinutes') { Ok 'exe: MaxSliceMinutes timeout wired' } else { Bad 'exe: MaxSliceMinutes missing' }
if ($launchSrc -match '\[string\]\$Engine') { Ok 'launch: -Engine param' } else { Bad 'launch: -Engine missing' }
if ($launchSrc -match 'ENGINE_PREFLIGHT|Resolve-AutoproEngine') { Ok 'launch: engine preflight' } else { Bad 'launch: engine preflight missing' }

$wePath = Join-Path $Scripts 'worker-engines.ps1'
if (Test-Path -LiteralPath $wePath) {
  $weSrc = Get-Content -LiteralPath $wePath -Raw
  if ($weSrc -match "ps1\|cmd" -or $weSrc -match 'shim') { Ok 'exe: shim rejection in worker-engines' } else { Bad 'exe: shim note missing in worker-engines' }
  if ($weSrc -match "ValidateSet\('claude', 'codex', 'gemini', 'grok', 'ollama'\)" -or $weSrc -match "claude.*codex.*gemini") {
    Ok 'exe: five engines listed'
  } else { Bad 'exe: engine set incomplete' }
} else { Bad 'exe: worker-engines.ps1 missing' }

# Simulate Resolve-ClaudeExe preference: never accept .ps1 path as result shape
$fakePs1 = Join-Path $env:TEMP 'claude.ps1'
'Write-Host shim' | Set-Content -LiteralPath $fakePs1 -Encoding utf8
try {
  # Inline mirror of the .exe-only filter
  $candidates = @($fakePs1, (Join-Path $env:USERPROFILE '.local\bin\claude.exe'))
  $resolved = $null
  foreach ($cand in $candidates) {
    if ($cand -and (Test-Path -LiteralPath $cand) -and ($cand -match '\.exe$')) {
      $resolved = $cand
      break
    }
  }
  if ($resolved -and $resolved -match '\.exe$') { Ok 'exe: filter skips .ps1 shim when .exe exists (or only exe)' }
  elseif (-not $resolved -and -not (Test-Path (Join-Path $env:USERPROFILE '.local\bin\claude.exe'))) {
    Ok 'exe: filter rejects .ps1 when no .exe (null)'
  } else { Bad 'exe: filter accepted non-exe' }
  if ($resolved -and $resolved -match '\.ps1$') { Bad 'exe: resolved to ps1' } else { Ok 'exe: never resolves to .ps1' }
} finally {
  Remove-Item -LiteralPath $fakePs1 -Force -ErrorAction SilentlyContinue
}

# ---- P1-T2: zero-progress abort ---------------------------------------------
if ($runnerSrc -match 'ZeroProgressStreak' -and $runnerSrc -match 'ZeroProgressLimit\s*=\s*2') {
  Ok 'zero: streak limit = 2'
} else { Bad 'zero: ZeroProgressStreak/Limit missing' }
if ($runnerSrc -match 'zero-progress-abort') { Ok 'zero: blocked outcome token' } else { Bad 'zero: outcome token missing' }
if ($runnerSrc -match 'refusing to spin the iteration cap') { Ok 'zero: stop message present' } else { Bad 'zero: stop message missing' }

# Pure streak logic unit (mirror of runner loop decision)
function Test-ZeroProgressLogic {
  param([int[]]$Events) # 1 = progress, 0 = empty
  $streak = 0
  $limit = 2
  $aborted = $false
  foreach ($e in $Events) {
    if ($e -eq 0) {
      $streak++
      if ($streak -ge $limit) { $aborted = $true; break }
    } else { $streak = 0 }
  }
  return $aborted
}
if (Test-ZeroProgressLogic @(0, 0)) { Ok 'zero: two empties abort' } else { Bad 'zero: two empties must abort' }
if (-not (Test-ZeroProgressLogic @(0, 1, 0))) { Ok 'zero: progress resets streak' } else { Bad 'zero: progress must reset streak' }
if (-not (Test-ZeroProgressLogic @(0))) { Ok 'zero: single empty continues' } else { Bad 'zero: single empty must not abort' }

# ---- P1-T5: NoShowTime on launch --------------------------------------------
if ($launchSrc -match '\[switch\]\$NoShowTime') { Ok 'headless: -NoShowTime switch' } else { Bad 'headless: switch missing' }
if ($launchSrc -match 'skipping theater ensure/register/open' -or $launchSrc -match '-NoShowTime — skipping') {
  Ok 'headless: skips theater path'
} else { Bad 'headless: theater skip path missing' }
if ($launchSrc -match "runnerArgParts \+= '-NoShowTime'" -or $launchSrc -match "\-NoShowTime'") {
  Ok 'headless: forwards -NoShowTime to runner'
} else { Bad 'headless: runner forward missing' }
if ($launchSrc -match 'HEADLESS=1') { Ok 'headless: prints HEADLESS=1' } else { Bad 'headless: HEADLESS marker missing' }

# ---- P1-T3/T4: detach + boot liveness ----------------------------------------
# Detach now routes through the cross-OS helper (Windows = same Win32_Process.Create underneath).
$procSrc = Get-Content -LiteralPath (Join-Path $Scripts 'proc-crossos.ps1') -Raw
if ($launchSrc -match 'Start-DetachedProcess' -and
    $procSrc -match 'Win32_Process' -and $procSrc -match 'Create') {
  Ok 'detach: Start-DetachedProcess (Win32_Process.Create on Windows)'
} else { Bad 'detach: cross-OS detach path missing' }
if ($launchSrc -match 'function Quote-Arg') { Ok 'detach: Quote-Arg for ledger titles' } else { Bad 'detach: Quote-Arg missing' }
if ($launchSrc -match 'BOOT_WAIT' -and $launchSrc -match 'BOOT_OK=armed' -and $launchSrc -match 'BOOT_FAIL') {
  Ok 'boot: launch waits for armed: / fails closed'
} else { Bad 'boot: launch boot-wait missing' }
if ($launchSrc -match 'boot-fail-' -or $launchSrc -match 'BOOT_DISARMED') {
  Ok 'boot: disarms flag on silent start'
} else { Bad 'boot: disarm-on-fail missing' }
if ($runnerSrc -match "Write-SessionState -State 'booting'" -or $runnerSrc -match "State 'booting'") {
  Ok 'boot: runner writes booting + PID early'
} else { Bad 'boot: early booting state missing' }
if ($runnerSrc -match 'runnerPid\s*=\s*\$PID' -or $runnerSrc -match 'runnerPid\s*=\s*\$PID') {
  Ok 'boot: session state includes runnerPid'
} else {
  # ordered hashtable form
  if ($runnerSrc -match 'runnerPid') { Ok 'boot: runnerPid field present' } else { Bad 'boot: runnerPid not in Write-SessionState' }
}
if ($statusSrc -match 'reconcile-dead-runner' -or $statusSrc -match 'session-stale') {
  Ok 'boot: status reconciles dead running PID'
} else { Bad 'boot: status reconcile missing' }
if ($statusSrc -match "State = 'ZOMBIE'" -or $statusSrc -match "\$state = 'ZOMBIE'") {
  Ok 'boot: status surfaces ZOMBIE not healthy running'
} else { Bad 'boot: ZOMBIE state path missing' }

# Status reconcile unit: dead pid + running claim => not ARMED
function Test-StatusReconcile([string]$state, [bool]$pidAlive, [bool]$runnerMatch) {
  if ($runnerMatch) { return 'ARMED' }
  if ($state -match '^(running|armed|booting|finalizing)$' -and $pidAlive) { return 'ARMED' }
  if ($state -match '^(running|armed|booting|finalizing)$' -and -not $pidAlive) { return 'ZOMBIE' }
  return 'IDLE'
}
if ((Test-StatusReconcile 'running' $false $false) -eq 'ZOMBIE') { Ok 'boot: dead+running => ZOMBIE' } else { Bad 'boot: dead+running must be ZOMBIE' }
if ((Test-StatusReconcile 'running' $true $false) -eq 'ARMED') { Ok 'boot: alive+running => ARMED' } else { Bad 'boot: alive+running must be ARMED' }

# ---- P1-T6: Show Time holds ZERO git authority (disarmed) --------------------
# Was: detached-HEAD base resolution for the worktree finalizer. That whole
# lifecycle (arm -> commit -> merge -> prune) is deleted: it could strand work in
# an orphaned tree that only `finish` knew how to bring home. Now we assert the
# authority cannot come back.
if ($runnerSrc -notmatch 'showtime-worktree|showtime-scoped-commit') {
  Ok 'disarm: runner calls no worktree/commit script'
} else { Bad 'disarm: runner still references a deleted git script' }
if ($launchSrc -notmatch 'showtime-worktree') {
  Ok 'disarm: launch calls no worktree script'
} else { Bad 'disarm: launch still references showtime-worktree' }
if ($launchSrc -notmatch 'WORKTREE_PATH') {
  Ok 'disarm: launch creates no worktree'
} else { Bad 'disarm: launch still creates a worktree' }

# ---- P1-T7: independent gate in this repo -----------------------------------
$repoRoot = (Resolve-Path (Join-Path $Scripts '..\..\..\..')).Path
# Gate probe: skill may live in ~/.agents/skills (not inside a product repo).
# Prefer a known monorepo if present; otherwise verify the resolver API only.
. (Join-Path $Scripts 'showtime-final-check.ps1')
$candidateRepos = [System.Collections.Generic.List[string]]::new()
foreach ($c in @(
    'C:\LOOPLET\ai-sidebar',
    (Join-Path $env:USERPROFILE 'LOOPLET\ai-sidebar'),
    'C:\LOOPLET\ai-sidebar\extension'
  )) {
  if ($c -and (Test-Path -LiteralPath $c)) { [void]$candidateRepos.Add($c) }
}
# Prefer repos that already have an independent gate
$withGate = @($candidateRepos | Where-Object {
    (Test-Path (Join-Path $_ 'scripts\final-check.ps1')) -or (
      (Test-Path (Join-Path $_ 'package.json')) -and
      ((Get-Content (Join-Path $_ 'package.json') -Raw -ErrorAction SilentlyContinue) -match '"gate"\s*:')
    )
  })
if ($withGate.Count) {
  $repoRoot = $withGate[0]
} else {
  $repoRoot = if ($candidateRepos.Count) { $candidateRepos[0] } else { $null }
}
if ($repoRoot) {
  $finalCheck = Join-Path $repoRoot 'scripts\final-check.ps1'
  $pkg = Join-Path $repoRoot 'package.json'
  if (Test-Path -LiteralPath $finalCheck) { Ok "gate: final-check.ps1 present ($repoRoot)" } else { Ok 'gate: final-check.ps1 absent (optional)' }
  if (Test-Path -LiteralPath $pkg) {
    $pkgRaw = Get-Content -LiteralPath $pkg -Raw
    if ($pkgRaw -match '"gate"\s*:') { Ok 'gate: package.json has gate script' } else { Ok 'gate: package.json has no gate script (optional)' }
  }
  $spec = Resolve-IndependentFinalGate -WorkDir $repoRoot
  if ($spec.Kind -ne 'none') { Ok ("gate: Resolve-IndependentFinalGate kind={0}" -f $spec.Kind) }
  else { Ok 'gate: none in probe repo (arm would need -AllowModelOnlyFinalCheck or configure gate)' }
} else {
  Ok 'gate: no product repo nearby — resolver API only'
  if (Get-Command Resolve-IndependentFinalGate -ErrorAction SilentlyContinue) {
    Ok 'gate: Resolve-IndependentFinalGate exported'
  } else { Bad 'gate: Resolve-IndependentFinalGate missing' }
}

# Multi-engine unit suite (offline)
$engTest = Join-Path $Scripts 'test-worker-engines.ps1'
if (Test-Path -LiteralPath $engTest) {
  & pwsh -NoProfile -File $engTest | ForEach-Object {
    if ($_ -match '^FAIL') { Bad "engines: $_" } elseif ($_ -match '^PASS') { Ok 'engines: test-worker-engines PASS' }
  }
  if ($LASTEXITCODE -ne 0) { Bad "engines: test-worker-engines exit $LASTEXITCODE" }
} else { Bad 'engines: test-worker-engines.ps1 missing' }

Write-Output ''
if ($failed -gt 0) {
  Write-Output "==== FAILED: $failed ===="
  exit 1
}
Write-Output '==== ALL PASS ===='
exit 0
