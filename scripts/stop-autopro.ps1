<#
  stop-autopro.ps1 — hard disarm (flag + processes).

  Why "delete autopro-on" alone feels broken:
    The runner only checks the flag *between* slices. An in-flight
    `claude -p work` keeps running until that process exits.

  This script:
    1) Removes autopro-on under -Root (and common sibling repos if -All)
    2) Stops autopro-runner.ps1 processes for those roots
    3) Optionally kills their child `claude -p work` (default: yes)
    4) Heartbeats Show Time sessions to paused when possible

  Usage:
    pwsh -File stop-autopro.ps1 -Root '<YOUR-REPO-ROOT>'
    pwsh -File stop-autopro.ps1 -All
    pwsh -File stop-autopro.ps1 -All -KeepClaude   # leave mid-slice claude alone
#>
param(
  [string]$Root = '',
  [string]$SessionId = '',
  [string]$LedgerHash = '',
  [switch]$All,
  [switch]$KeepClaude,
  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'

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
  $found = @(Get-ChildItem -Path (Join-Path $r '.claude\scratch\autopro-on*') -File -ErrorAction SilentlyContinue)
  if ($SessionId) { $found = @($found | Where-Object { $_.Name -eq 'autopro-on' -or $_.Name -eq "autopro-on.$SessionId" }) }
  if ($found.Count) {
    foreach ($f in $found) {
      Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
      Say "FLAG_REMOVED=$($f.FullName)"
      $flagsRemoved++
    }
  } else {
    Say "FLAG_ABSENT=$r\.claude\scratch\autopro-on*"
  }
}

# 2) Find runners matching those roots (or any runner if -All)
$runners = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -match 'autopro-runner\.ps1' }

$killedRunners = @()
foreach ($proc in $runners) {
  if (-not (Test-ProcMatch $proc)) { continue }

  Say "KILL_RUNNER PID=$($proc.ProcessId)"
  try {
    # Kill process tree first; children include claude -p when parent still owns them.
    $taskkillOut = & taskkill.exe /PID $proc.ProcessId /T /F 2>&1
    $taskkillExit = $LASTEXITCODE
    $taskkillOut | ForEach-Object { Say "  $_" }
    if ($taskkillExit -ne 0) { throw "taskkill exit $taskkillExit" }
    $killedRunners += $proc.ProcessId
  } catch {
    try {
      Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
      $killedRunners += $proc.ProcessId
    } catch {
      Say "  warn: could not kill $($proc.ProcessId): $($_.Exception.Message)"
    }
  }
}

# 3) Orphan claude -p work (parent already dead)
if (-not $KeepClaude) {
  $claudes = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and
      ($_.Name -match 'claude' -or $_.CommandLine -match 'claude') -and
      $_.CommandLine -match '\s-p\s'
    }
  foreach ($c in $claudes) {
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($c.ParentProcessId)" -ErrorAction SilentlyContinue
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
      Say "KILL_CLAUDE PID=$($c.ProcessId) orphan=$orphan"
      try { Stop-Process -Id $c.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
      try { & taskkill.exe /PID $c.ProcessId /T /F 2>&1 | Out-Null } catch {}
    } elseif ($orphan) {
      Say "SKIP_ORPHAN_CLAUDE_UNSCOPED PID=$($c.ProcessId)"
    }
  }
}

# 4) Handovers + wipe dead/complete lanes off the board (processes already killed)
try {
  $portFile = Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater\server.port'
  $port = 8770
  if (Test-Path -LiteralPath $portFile) {
    $p = (Get-Content -LiteralPath $portFile -Raw).Trim()
    if ($p -match '^\d+$') { $port = [int]$p }
  }
  # After kill, pids are dead → treat as stale immediately so board clears
  $bodyObj = @{ staleAfterMs = 0; wipeComplete = $true }
  if ($LedgerHash) { $bodyObj.ledgerHash = $LedgerHash }
  $body = $bodyObj | ConvertTo-Json -Compress
  $tokFile = Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater\server.token'
  $tok = if (Test-Path -LiteralPath $tokFile) { (Get-Content -LiteralPath $tokFile -Raw).Trim() } else { '' }
  $pre = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/preflight" -Method POST -ContentType 'application/json' -Headers @{ 'X-Showtime-Token' = $tok } -Body $body -TimeoutSec 5
  Say ("BOARD_PREFLIGHT wiped={0} handoversFlushed={1}" -f @($pre.wiped).Count, $pre.handoversFlushed)
  if ($pre.outbox) { Say "HANDOVER_OUTBOX=$($pre.outbox)" }
} catch {
  Say "BOARD_PREFLIGHT_SKIP=$($_.Exception.Message)"
}

# 5) Verify
Start-Sleep -Milliseconds 400
$stillRunners = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -match 'autopro-runner\.ps1' -and (Test-ProcMatch $_) })
$stillClaude = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object {
    $_.CommandLine -and $_.CommandLine -match '\s-p\s' -and
    ($_.Name -match 'claude|node' -or $_.CommandLine -match 'claude') -and
    (Test-ClaudeMatch $_)
  })

Say ''
Say "FLAGS_REMOVED=$flagsRemoved"
Say "RUNNERS_KILLED=$($killedRunners.Count)"
Say "RUNNERS_STILL=$($stillRunners.Count)"
Say "CLAUDE_WORK_STILL=$($stillClaude.Count)"
if ($stillRunners.Count -eq 0 -and ($KeepClaude -or $stillClaude.Count -eq 0)) {
  Say 'STATUS=disarmed'
} else {
  Say 'STATUS=partial — check leftover PIDs above'
  $stillRunners | ForEach-Object { Say "  leftover runner PID=$($_.ProcessId)" }
  if (-not $KeepClaude) { $stillClaude | ForEach-Object { Say "  leftover claude PID=$($_.ProcessId)" } }
}
