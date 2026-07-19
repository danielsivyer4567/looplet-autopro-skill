<#
  stop-autopro.ps1 — hard disarm (flag + processes).

  Why "delete autopro-on" alone feels broken:
    The runner only checks the flag *between* slices. An in-flight
    worker (claude / codex / gemini / grok / ollama) keeps running until exit.

  This script:
    1) Removes autopro-on under -Root (and common sibling repos if -All)
    2) Stops autopro-runner.ps1 processes for those roots
    3) Optionally kills orphan worker CLIs (default: yes)
    4) Heartbeats Show Time sessions to paused when possible

  Usage:
    pwsh -File stop-autopro.ps1 -Root '<YOUR-REPO-ROOT>'
    pwsh -File stop-autopro.ps1 -All
    pwsh -File stop-autopro.ps1 -All -KeepClaude   # leave mid-slice workers alone
    # -KeepWorker is an alias of -KeepClaude
#>
param(
  [string]$Root = '',
  [string]$SessionId = '',
  [string]$LedgerHash = '',
  [switch]$All,
  [switch]$KeepClaude,
  [Alias('KeepWorker')][switch]$KeepWorkers,
  [switch]$Quiet
)
if ($KeepWorkers) { $KeepClaude = $true }

$ErrorActionPreference = 'Continue'
$enginesPs1 = Join-Path $PSScriptRoot 'worker-engines.ps1'
if (Test-Path -LiteralPath $enginesPs1) { . $enginesPs1 }
# Cross-platform process enumeration + tree-kill (Windows path is the same CIM/taskkill as before).
. (Join-Path $PSScriptRoot 'proc-crossos.ps1')

function Say([string]$m) {
  if (-not $Quiet) { Write-Output $m }
}

function Test-ProcMatch($proc) {
  if (-not $proc.CommandLine) { return $false }
  $cmd = [string]$proc.CommandLine
  if ($All) { return $true }
  $rootMatch = $false
  foreach ($r in $roots) {
    if ($cmd -like "*$r*") { $rootMatch = $true; break }
  }
  if (-not $rootMatch) { return $false }
  if ($SessionId -and $cmd -notlike "*$SessionId*") { return $false }
  if ($LedgerHash -and $cmd -notlike "*$LedgerHash*") { return $false }
  return $true
}

function Test-ClaudeMatch($proc) {
  if ($All) { return $true }
  if ($SessionId -and $proc.CommandLine -like "*$SessionId*") { return $true }
  if ($LedgerHash -and $proc.CommandLine -like "*$LedgerHash*") { return $true }
  if (-not $SessionId -and -not $LedgerHash) {
    foreach ($r in $roots) {
      if ($proc.CommandLine -like "*$r*") { return $true }
    }
  }
  return $false
}

if (-not $All -and -not $Root) {
  Write-Output 'Pass -Root <repo> to stop one repo, or -All to stop every known root. Refusing to guess.'
  exit 64
}

$roots = [System.Collections.Generic.List[string]]::new()
if ($Root) { $roots.Add((Resolve-Path -LiteralPath $Root -ErrorAction SilentlyContinue)?.Path ?? $Root) }
if ($All) {
  foreach ($c in @(
      '<YOUR-REPO-ROOT>',
      '<YOUR-REPO-ROOT>',
      '<YOUR-REPO-ROOT>',
      '<YOUR-REPO-ROOT>'
    )) {
    if (Test-Path -LiteralPath $c) { [void]$roots.Add($c) }
  }
}
# unique
$roots = @($roots | Select-Object -Unique)

Say '==== stop-autopro ===='

# 1) Flags (bare legacy 'autopro-on' plus per-session 'autopro-on.<sessionId>')
$flagsRemoved = 0
foreach ($r in $roots) {
  $found = @(Get-ChildItem -Path (Join-Path $r '.claude/scratch/autopro-on*') -File -ErrorAction SilentlyContinue)
  # The ultra flag is literally 'autopro-on.ultra' (runId is its CONTENT, not
  # the filename), so a -SessionId of sess_ultra_<runId> must NOT narrow it out.
  if ($SessionId) { $found = @($found | Where-Object { $_.Name -eq 'autopro-on' -or $_.Name -eq "autopro-on.$SessionId" -or $_.Name -eq 'autopro-on.ultra' -or $_.Name -like 'autopro-on.band-*' }) }
  if ($found.Count) {
    foreach ($f in $found) {
      Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
      Say "FLAG_REMOVED=$($f.FullName)"
      $flagsRemoved++
    }
  } else {
    Say "FLAG_ABSENT=$r\.claude/scratch/autopro-on*"
  }
}

# 2) Find runners matching those roots (or any runner if -All). Includes the
# ultra orchestrators (autopro-ultra.ps1 / ultra-resume.ps1) — killing their
# tree reaps every band wrapper + engine child in one shot.
$runners = Get-AutoproProcessList -Names @('pwsh', 'powershell') |
  Where-Object { $_.CommandLine -and $_.CommandLine -match 'autopro-runner\.ps1|autopro-ultra\.ps1|ultra-resume\.ps1' }

$killedRunners = @()
foreach ($proc in $runners) {
  if (-not (Test-ProcMatch $proc)) { continue }

  Say "KILL_RUNNER PID=$($proc.ProcessId)"
  # Kill the tree — children include `claude -p` while the parent still owns them.
  if (Stop-ProcessTree -Id $proc.ProcessId) {
    $killedRunners += $proc.ProcessId
  } else {
    Say "  warn: could not kill $($proc.ProcessId)"
  }
}

# 2b) Ultra: the detached orchestrator (autopro-ultra/ultra-resume) writes its
# PID to ultra-orchestrator.pid and every band's workerPid into ultra-state.json.
# Kill the orchestrator tree (reaps band wrappers + engine children), then each
# recorded band pid for already-orphaned/resumed cases. This is what makes
# `stop-autopro -Root <repo>` actually stop an ultra fleet.
foreach ($r in @($roots)) {
  $ultraState = Join-Path $r '.claude/scratch/ultra-state.json'
  $st = $null
  if (Test-Path -LiteralPath $ultraState) {
    try { $st = Get-Content -LiteralPath $ultraState -Raw | ConvertFrom-Json } catch { $st = $null }
  }
  # Worktrees + band command lines live under RepoDir, which may differ from
  # -Root. Add it to the match set so scoped worker/orphan matching still sees them.
  if ($st -and $st.repoDir -and (Test-Path -LiteralPath ([string]$st.repoDir))) {
    if (-not ($roots -contains [string]$st.repoDir)) { $roots += [string]$st.repoDir }
  }
  $ultraRepoDir = if ($st -and $st.repoDir) { [string]$st.repoDir } else { $r }

  $ultraPidFile = Join-Path $r '.claude/scratch/ultra-orchestrator.pid'
  if (Test-Path -LiteralPath $ultraPidFile) {
    $op = 0; try { $op = [int]((Get-Content -LiteralPath $ultraPidFile -Raw).Trim()) } catch {}
    if ($op -gt 0 -and (Get-Process -Id $op -ErrorAction SilentlyContinue)) {
      Say "KILL_ULTRA_ORCH PID=$op root=$r"
      [void](Stop-ProcessTree -Id $op)
    }
    Remove-Item -LiteralPath $ultraPidFile -Force -ErrorAction SilentlyContinue
  }
  if ($st) {
    foreach ($b in @($st.bands)) {
      $bp = 0; if ($b.workerPid) { [void][int]::TryParse([string]$b.workerPid, [ref]$bp) }
      if ($bp -gt 0 -and (Get-Process -Id $bp -ErrorAction SilentlyContinue)) {
        Say "KILL_ULTRA_BAND PID=$bp band=$($b.bandId) root=$r"
        [void](Stop-ProcessTree -Id $bp)
      }
    }
  }
  # Per-band flags live inside the worktrees (under RepoDir) — clear them so a
  # resume doesn't think a band is still armed.
  $wtGlob = Join-Path $ultraRepoDir '.worktrees-ultra'
  if (Test-Path -LiteralPath $wtGlob) {
    foreach ($bf in @(Get-ChildItem -Path $wtGlob -Recurse -Filter 'autopro-on.band-*' -File -ErrorAction SilentlyContinue)) {
      Remove-Item -LiteralPath $bf.FullName -Force -ErrorAction SilentlyContinue
      Say "BAND_FLAG_REMOVED=$($bf.FullName)"
    }
  }
}
$roots = @($roots | Select-Object -Unique)

# 3) Orphan workers (claude / codex / gemini / grok / ollama / node cli.js) when parent already dead
function Test-IsWorkerProc($proc) {
  if (-not $proc.CommandLine) { return $false }
  $cmd = [string]$proc.CommandLine
  if (Get-Command Test-WorkerCommandLine -ErrorAction SilentlyContinue) {
    return (Test-WorkerCommandLine -CommandLine $cmd)
  }
  # Fallback if worker-engines.ps1 missing
  return ($cmd -match 'claude|codex\.js|@openai\\codex|gemini\.js|@google\\gemini-cli|grok\.exe|ollama')
}

if (-not $KeepClaude) {
  # Also kill PIDs recorded by runner (autopro-worker.pid)
  foreach ($r in $roots) {
    $pidFile = Join-Path $r '.claude/scratch/autopro-worker.pid'
    if (Test-Path -LiteralPath $pidFile) {
      $wp = 0
      try { $wp = [int]((Get-Content -LiteralPath $pidFile -Raw).Trim()) } catch {}
      if ($wp -gt 0) {
        Say "KILL_WORKER_PIDFILE PID=$wp root=$r"
        [void](Stop-ProcessTree -Id $wp)
      }
      Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
  }

  # Prefer filtered queries — unfiltered enumerations hang on busy machines. The name set covers
  # every worker CLI plus their likely parent (the runner is pwsh); Test-IsWorkerProc does the
  # real filtering on the command line, cross-OS.
  $workers = @(
    Get-AutoproProcessList -Names @('claude', 'node', 'grok', 'ollama', 'codex', 'pwsh', 'powershell') |
      Where-Object { $_.CommandLine -and (Test-IsWorkerProc $_) } |
      Sort-Object ProcessId -Unique
  )
  foreach ($c in $workers) {
    # Look the parent up by PID (any process, not just worker-type) so a live runner parent is seen.
    $parent = Get-AutoproProcessById -Id $c.ParentProcessId
    $orphan = -not $parent
    $parentIsRunner = $parent -and $parent.CommandLine -match 'autopro-runner' -and (Test-ProcMatch $parent)
    $safeOrphanMatch = $All
    if (-not $safeOrphanMatch -and $orphan) {
      foreach ($r in $roots) {
        if ($c.CommandLine -like "*$r*") { $safeOrphanMatch = $true; break }
      }
      if ($SessionId -and $c.CommandLine -notlike "*$SessionId*") { $safeOrphanMatch = $false }
      if ($LedgerHash -and $c.CommandLine -notlike "*$LedgerHash*") { $safeOrphanMatch = $false }
    }
    if ($parentIsRunner -or $safeOrphanMatch) {
      Say "KILL_WORKER PID=$($c.ProcessId) orphan=$orphan name=$($c.Name)"
      [void](Stop-ProcessTree -Id $c.ProcessId)
    } elseif ($orphan) {
      Say "SKIP_ORPHAN_WORKER_UNSCOPED PID=$($c.ProcessId)"
    }
  }
}

# 4) Handovers + wipe dead/complete lanes off the board (processes already killed)
try {
  $portFile = Join-Path ($env:USERPROFILE ?? $HOME) '.claude/scratch/autopro-theater/server.port'
  $port = 8770
  if (Test-Path -LiteralPath $portFile) {
    $p = (Get-Content -LiteralPath $portFile -Raw).Trim()
    if ($p -match '^\d+$') { $port = [int]$p }
  }
  # After kill, pids are dead → treat as stale immediately so board clears
  $bodyObj = @{ staleAfterMs = 0; wipeComplete = $true }
  if ($LedgerHash) { $bodyObj.ledgerHash = $LedgerHash }
  $body = $bodyObj | ConvertTo-Json -Compress
  $tokFile = Join-Path ($env:USERPROFILE ?? $HOME) '.claude/scratch/autopro-theater/server.token'
  $tok = if (Test-Path -LiteralPath $tokFile) { (Get-Content -LiteralPath $tokFile -Raw).Trim() } else { '' }
  $pre = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/preflight" -Method POST -ContentType 'application/json' -Headers @{ 'X-Showtime-Token' = $tok } -Body $body -TimeoutSec 5
  Say ("BOARD_PREFLIGHT wiped={0} handoversFlushed={1}" -f @($pre.wiped).Count, $pre.handoversFlushed)
  if ($pre.outbox) { Say "HANDOVER_OUTBOX=$($pre.outbox)" }
} catch {
  Say "BOARD_PREFLIGHT_SKIP=$($_.Exception.Message)"
}

# 5) Verify
Start-Sleep -Milliseconds 400
$stillRunners = @(Get-AutoproProcessList -Names @('pwsh', 'powershell') |
  Where-Object { $_.CommandLine -and $_.CommandLine -match 'autopro-runner\.ps1|autopro-ultra\.ps1|ultra-resume\.ps1' -and (Test-ProcMatch $_) })
$stillWorkers = @(Get-AutoproProcessList -Names @('claude', 'node', 'grok', 'ollama', 'codex') |
  Where-Object { (Test-IsWorkerProc $_) -and (Test-ClaudeMatch $_) })

Say ''
Say "FLAGS_REMOVED=$flagsRemoved"
Say "RUNNERS_KILLED=$($killedRunners.Count)"
Say "RUNNERS_STILL=$($stillRunners.Count)"
Say "WORKERS_STILL=$($stillWorkers.Count)"
if ($stillRunners.Count -eq 0 -and ($KeepClaude -or $stillWorkers.Count -eq 0)) {
  Say 'STATUS=disarmed'
} else {
  Say 'STATUS=partial — check leftover PIDs above'
  $stillRunners | ForEach-Object { Say "  leftover runner PID=$($_.ProcessId)" }
  if (-not $KeepClaude) { $stillWorkers | ForEach-Object { Say "  leftover worker PID=$($_.ProcessId) name=$($_.Name)" } }
}
