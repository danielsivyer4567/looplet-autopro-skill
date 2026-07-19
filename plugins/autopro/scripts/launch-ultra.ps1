# launch-ultra.ps1 — arm boring-safe parallel band autopro
#
# Housing layer only: worktrees, bands, queue, ledger. Worker engine is
# whatever the operator uses (-Engine auto|claude|codex|gemini|grok).
# Creates NO main merges. Worktrees retained on stop.
param(
  [Parameter(Mandatory = $true)][string]$Root,
  [Parameter(Mandatory = $true)][string]$RepoDir,
  [int]$BandSize = 5,
  [int]$MaxConcurrency = 3,
  [ValidateSet('even', 'pack')][string]$SplitMode = 'even',
  [switch]$UnblockPaused,
  [switch]$AllowDangerousSkipPermissions,
  [switch]$IAcceptUnattendedRisk,
  [switch]$NoSliceVerifier,
  [switch]$AllowOllama,
  [int]$MaxBandMinutes = 120,
  [string]$Engine = 'auto',
  [string]$Model = '',
  [switch]$RequireBoard,
  [int]$StallMinutes = 12
)

$ErrorActionPreference = 'Stop'
if (-not $AllowDangerousSkipPermissions -or -not $IAcceptUnattendedRisk) {
  throw @'
Refusing to arm ultra without risk acceptance.
Pass BOTH:
  -AllowDangerousSkipPermissions
  -IAcceptUnattendedRisk
'@
}

$Root = (Resolve-Path -LiteralPath $Root).Path
$RepoDir = (Resolve-Path -LiteralPath $RepoDir).Path
$Ultra = Join-Path $PSScriptRoot 'autopro-ultra.ps1'
# Cross-platform detached spawn (Windows path is the same Win32_Process.Create as before).
. (Join-Path $PSScriptRoot 'proc-crossos.ps1')
$scratch = Join-Path $Root '.claude/scratch'
if (-not (Test-Path $scratch)) { New-Item -ItemType Directory -Path $scratch -Force | Out-Null }

# Singleton lease: refuse to arm a SECOND ultra orchestrator on this root while
# one is already armed and alive. Two same-repo orchestrators would share the
# working tree and could force-remove each other's live band worktrees.
$leaseFlag = Join-Path $scratch 'autopro-on.ultra'
$leasePidFile = Join-Path $scratch 'ultra-orchestrator.pid'
if ((Test-Path -LiteralPath $leaseFlag) -and (Test-Path -LiteralPath $leasePidFile)) {
  $leasePid = 0
  try { $leasePid = [int]((Get-Content -LiteralPath $leasePidFile -Raw).Trim()) } catch {}
  if ($leasePid -gt 0 -and (Get-Process -Id $leasePid -ErrorAction SilentlyContinue)) {
    throw "Ultra already armed on this root (orchestrator PID $leasePid alive). Stop it first: stop-autopro.ps1 -Root '$Root'"
  }
}

Write-Output 'ULTRA_MODE=boring-safe-parallel'
Write-Output 'HOUSING=structure-only (worktrees/bands/ledger/board — not a model vendor)'
Write-Output "BAND_SIZE=$BandSize MAX_CONCURRENCY=$MaxConcurrency SPLIT=$SplitMode"
Write-Output "ENGINE_REQUEST=$Engine MODEL=$Model"
Write-Output 'MERGE_TO_MAIN=never (integration/manual only)'
Write-Output 'WORKTREES=kept-on-stop'

$pwsh = (Get-Command pwsh).Source
function Q([string]$s) {
  if ($null -eq $s) { return '""' }
  if ($s -match '[\s"]') { return '"' + ($s -replace '"', '\"') + '"' }
  return $s
}
$cmd = '"{0}" -NoProfile -File {1} -Root {2} -RepoDir {3} -BandSize {4} -MaxConcurrency {5} -SplitMode {6} -Engine {7} -AllowDangerousSkipPermissions -IAcceptUnattendedRisk -MaxBandMinutes {8} -StallMinutes {9}' -f `
  $pwsh, (Q $Ultra), (Q $Root), (Q $RepoDir), $BandSize, $MaxConcurrency, $SplitMode, (Q $Engine), $MaxBandMinutes, $StallMinutes
if ($Model) { $cmd += " -Model $(Q $Model)" }
if ($UnblockPaused) { $cmd += ' -UnblockPaused' }
if ($NoSliceVerifier) { $cmd += ' -NoSliceVerifier' }
if ($AllowOllama) { $cmd += ' -AllowOllama' }
if ($RequireBoard) { $cmd += ' -RequireBoard' }

Write-Output "STALL_MINUTES=$StallMinutes REQUIRE_BOARD=$RequireBoard"

$created = Start-DetachedProcess -CommandLine $cmd -CurrentDirectory $RepoDir
if ($created.ReturnValue -ne 0 -or -not $created.ProcessId) {
  throw "Failed to detach ultra orchestrator: $($created.ReturnValue)"
}

$orchPid = [int]$created.ProcessId
Set-Content -LiteralPath (Join-Path $scratch 'ultra-orchestrator.pid') -Value $orchPid
Write-Output "ORCH_PID=$orchPid"
Write-Output "ULTRA_LOG=$(Join-Path $scratch 'ultra.log')"
Write-Output "STATE=$(Join-Path $scratch 'ultra-state.json')"
Write-Output 'Board: open sketches or Show Time; workers are per-band worktrees under .worktrees-ultra\'
Write-Output 'Stop: remove .claude/scratch/autopro-on.ultra and stop band claude PIDs (or stop-autopro.ps1 -Root)'

# Best-effort open board sketch
$sketch = Join-Path $RepoDir '.claude/scratch/ultra-safe-sketch.html'
if (Test-Path $sketch) {
  $chrome = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  $uri = 'file:///' + ($sketch -replace '\\', '/')
  if ($chrome) { Start-Process $chrome $uri }
}

# Boot wait for log
$log = Join-Path $scratch 'ultra.log'
$deadline = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadline) {
  if (Test-Path $log) {
    $tail = Get-Content $log -Tail 5 -ErrorAction SilentlyContinue
    if ($tail -match 'scheduler start|worktree B01|No runnable') {
      Write-Output 'BOOT_OK=ultra-armed'
      $tail | ForEach-Object { Write-Output $_ }
      break
    }
  }
  Start-Sleep -Seconds 2
}
if (-not (Test-Path $log)) { Write-Output 'BOOT_WAIT=log-not-yet' }
