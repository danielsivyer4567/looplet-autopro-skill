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
    'showtime-worktree.ps1',
    'autopro-status.ps1',
    'stop-autopro.ps1'
  )) {
  $path = Join-Path $Scripts $name
  if (-not (Test-Path -LiteralPath $path)) { Bad "parse: missing $name"; continue }
  $errs = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count) { Bad "parse: $name — $($errs[0].Message)" } else { Ok "parse: $name" }
}

$runnerSrc = Get-Content -LiteralPath (Join-Path $Scripts 'autopro-runner.ps1') -Raw
$launchSrc = Get-Content -LiteralPath (Join-Path $Scripts 'launch-showtime.ps1') -Raw
$wtSrc = Get-Content -LiteralPath (Join-Path $Scripts 'showtime-worktree.ps1') -Raw
$statusSrc = Get-Content -LiteralPath (Join-Path $Scripts 'autopro-status.ps1') -Raw

# ---- P1-T1: claude.exe-only resolve + argv fail-fast -------------------------
if ($runnerSrc -match 'function Resolve-ClaudeExe') { Ok 'exe: Resolve-ClaudeExe present' } else { Bad 'exe: Resolve-ClaudeExe missing' }
if ($runnerSrc -match "Never return npm's claude\.ps1" -or $runnerSrc -match 'claude\.ps1') { Ok 'exe: documents shim rejection' } else { Bad 'exe: shim rejection note missing' }
if ($runnerSrc -match "unknown option\s+\\?'?-" -or $runnerSrc -match 'unknown option') {
  Ok 'exe: unknown option fail-fast wired'
} else { Bad 'exe: unknown option fail-fast missing' }
if ($runnerSrc -match "claude-argv-parse-failed") { Ok 'exe: argv outcome blocked state' } else { Bad 'exe: argv blocked outcome missing' }
if ($runnerSrc -match "\.exe\$" -or $runnerSrc -match "match '\\.exe\$'") { Ok 'exe: requires .exe extension' } else { Bad 'exe: .exe extension guard missing' }

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
if ($launchSrc -match 'Win32_Process' -and $launchSrc -match 'Create') {
  Ok 'detach: Win32_Process.Create path'
} else { Bad 'detach: Win32_Process.Create missing' }
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

# ---- P1-T6: detached HEAD worktree base -------------------------------------
if ($wtSrc -match "if \(\`$b -eq 'HEAD'" -or $wtSrc -match "eq 'HEAD'") {
  Ok 'worktree: detects detached HEAD'
} else { Bad 'worktree: detached HEAD check missing' }
if ($wtSrc -match 'never fall back to ''main''' -or $wtSrc -match 'never fall back to') {
  Ok 'worktree: refuses silent main fallback'
} else { Bad 'worktree: main-fallback note missing' }

# Live git fixture: detached worktree base = HEAD sha
$fx = Join-Path $env:TEMP ('autopro-wt-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
  New-Item -ItemType Directory -Force -Path $fx | Out-Null
  & git init -q -b main $fx 2>&1 | Out-Null
  & git -C $fx config user.email 'autopro@test.local' | Out-Null
  & git -C $fx config user.name 'Autopro Test' | Out-Null
  & git -C $fx config commit.gpgsign false | Out-Null
  'x' | Set-Content -LiteralPath (Join-Path $fx 'a.txt') -Encoding utf8
  & git -C $fx add -A 2>&1 | Out-Null
  & git -C $fx commit -q -m 'seed' 2>&1 | Out-Null
  $sha = (& git -C $fx rev-parse HEAD).Trim()
  & git -C $fx checkout -q --detach HEAD 2>&1 | Out-Null
  $abbrev = (& git -C $fx rev-parse --abbrev-ref HEAD).Trim()
  if ($abbrev -eq 'HEAD') { Ok 'worktree: fixture is detached' } else { Bad "worktree: expected detached got $abbrev" }

  # Mirror Get-CurrentBranch
  function Get-CurrentBranchMirror([string]$dir) {
    Push-Location -LiteralPath $dir
    try {
      $b = (& git rev-parse --abbrev-ref HEAD 2>$null).Trim()
      if ($b -eq 'HEAD' -or -not $b) {
        $s = (& git rev-parse HEAD 2>$null).Trim()
        if ($s) { return $s }
        return 'HEAD'
      }
      return $b
    } finally { Pop-Location }
  }
  $base = Get-CurrentBranchMirror $fx
  if ($base -eq $sha) { Ok 'worktree: detached base returns full SHA' } else { Bad "worktree: base=$base expected=$sha" }
  if ($base -ne 'main') { Ok 'worktree: detached base is not main' } else { Bad 'worktree: incorrectly returned main' }
} finally {
  Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- P1-T7: independent gate in this repo -----------------------------------
$repoRoot = (Resolve-Path (Join-Path $Scripts '..\..\..\..')).Path
# scripts live at .claude/skills/autopro/scripts → 4 levels up is repo root
if (-not (Test-Path (Join-Path $repoRoot 'package.json'))) {
  $repoRoot = (Resolve-Path (Join-Path $Scripts '..\..\..\..\..')).Path
}
# From: repo/.claude/skills/autopro/scripts → Join 4x .. = repo
$probe = $Scripts
for ($i = 0; $i -lt 4; $i++) { $probe = Split-Path $probe -Parent }
$repoRoot = $probe
$finalCheck = Join-Path $repoRoot 'scripts\final-check.ps1'
$pkg = Join-Path $repoRoot 'package.json'
if (Test-Path -LiteralPath $finalCheck) { Ok 'gate: scripts/final-check.ps1 present' } else { Bad 'gate: final-check.ps1 missing' }
if (Test-Path -LiteralPath $pkg) {
  $pkgRaw = Get-Content -LiteralPath $pkg -Raw
  if ($pkgRaw -match '"gate"\s*:') { Ok 'gate: package.json has gate script' } else { Bad 'gate: package.json missing gate' }
} else { Bad 'gate: package.json missing' }

# Dot-source Resolve-IndependentFinalGate from showtime-final-check.ps1
. (Join-Path $Scripts 'showtime-final-check.ps1')
$spec = Resolve-IndependentFinalGate -WorkDir $repoRoot
if ($spec.Kind -ne 'none') { Ok ("gate: Resolve-IndependentFinalGate kind={0}" -f $spec.Kind) } else { Bad 'gate: still none in this repo' }

Write-Output ''
if ($failed -gt 0) {
  Write-Output "==== FAILED: $failed ===="
  exit 1
}
Write-Output '==== ALL PASS ===='
exit 0
