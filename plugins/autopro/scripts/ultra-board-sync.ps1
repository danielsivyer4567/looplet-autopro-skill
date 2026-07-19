# ultra-board-sync.ps1 — keep Show Time truthful while ultra runs
# Reads ultra-state.json, pushes ONE orch + one SA lane per band with live pids.
# Each SC card carries the human task title from the ledger.
# Safe to run alongside an already-started autopro-ultra orchestrator.
param(
  [string]$Root = '',
  [string]$RepoDir = '',
  [int]$IntervalSec = 15
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'showtime-board-gate.ps1')
. (Join-Path $PSScriptRoot 'ultra-band-lib.ps1')

if (-not $Root) { $Root = (Get-Location).Path }
if (-not $RepoDir) { $RepoDir = $Root }
$Root = (Resolve-Path -LiteralPath $Root).Path
$RepoDir = (Resolve-Path -LiteralPath $RepoDir).Path
$statePath = Join-Path $Root '.claude\scratch\ultra-state.json'
$flag = Join-Path $Root '.claude\scratch\autopro-on.ultra'
$log = Join-Path $Root '.claude\scratch\ultra.log'
$ledger = Join-Path $RepoDir '.claude\scratch\ledger.md'

function L([string]$m) {
  $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] BOARD-SYNC $m"
  Write-Host $line
  try { Add-Content -LiteralPath $log -Value $line } catch {}
}

function Sync-Once {
  if (-not (Test-Path -LiteralPath $statePath)) { L 'no ultra-state.json'; return }
  $s = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
  $runId = [string]$s.runId
  if (-not $runId) { return }
  $titleMap = Get-LedgerTitleMap -LedgerPath $ledger

  $livePids = [System.Collections.Generic.List[int]]::new()
  $liveBands = [System.Collections.Generic.List[string]]::new()
  foreach ($b in @($s.bands)) {
    if ([string]$b.state -ne 'running' -or -not $b.workerPid) { continue }
    $wp = 0
    if (-not [int]::TryParse([string]$b.workerPid, [ref]$wp)) { continue }
    if (Get-Process -Id $wp -ErrorAction SilentlyContinue) {
      [void]$livePids.Add($wp)
      [void]$liveBands.Add([string]$b.bandId)
    }
  }

  # --- ORCH head (desk only — never steals a band worker pid) ---
  $orchSess = "sess_ultra_$runId"
  $runningN = $livePids.Count
  $queuedN = @($s.bands | Where-Object { $_.state -eq 'queued' }).Count
  $doneN = @($s.bands | Where-Object { $_.state -eq 'done' }).Count
  $stallN = @($s.bands | Where-Object { $_.state -match 'fail|stall' }).Count
  $orch = @{
    sessionId         = $orchSess
    repoPath          = $RepoDir
    primaryRepoPath   = $RepoDir
    repoId            = [IO.Path]::GetFileName($RepoDir.TrimEnd('\', '/'))
    branch            = 'main'
    status            = $(if ($runningN) { 'running' } else { 'idle' })
    pid               = 0
    runnerPid         = 0
    role              = 'orch'
    chatLabel         = 'ORCH'
    ledgerTitle       = 'OTIS Computer Fluency (full 50)'
    # clear join-time master ledger so heartbeats never re-inflate 50 SCs onto ORCH
    ledgerPath        = $null
    logPath           = $log
    slice             = @{
      id    = 'ORCH'
      title = "ORCH · ultra live=$runningN ($($liveBands -join ', '))"
      state = $(if ($runningN) { 'in-progress' } else { 'pending' })
      total = @($s.bands).Count
      index = 0
    }
    counts            = @{
      pending    = $queuedN
      done       = $doneN
      inProgress = $runningN
      blocked    = $stallN
      standby    = 0
    }
    # non-empty so server will NOT parseLedgerTodos
    todo              = @(
      @{
        id    = 'FLEET'
        text  = "Fleet live=$runningN · queued=$queuedN · doneBands=$doneN · stalled=$stallN"
        state = $(if ($runningN) { 'in-progress' } else { 'pending' })
      }
    )
    stats             = @{ engine = $s.engine; engineDisplay = $s.engineDisplay }
  }
  try {
    if (-not (Test-BoardSessionPresent -SessionId $orchSess)) {
      $null = Assert-BoardSessionRegistered -SessionId $orchSess -RepoPath $RepoDir -Branch main `
        -LedgerPath '' -LedgerTitle $orch.ledgerTitle -RunnerPid 0 `
        -AllowAutoApprove -RegisterBody $orch -Retries 2
    }
    $null = Invoke-BoardApi -Method POST -Path '/api/sessions' -Body $orch
  } catch {
    try { $null = Invoke-BoardApi -Method POST -Path "/api/sessions/$orchSess/heartbeat" -Body $orch } catch {}
  }

  # --- One SA lane per band ---
  $n = 0
  $cardSamples = [System.Collections.Generic.List[string]]::new()
  foreach ($b in @($s.bands)) {
    $n++
    $bid = [string]$b.bandId
    $bandSess = "sess_${runId}_${bid}"
    $wt = [string]$b.worktree
    if (-not $wt) { $wt = Join-Path $RepoDir ".worktrees-ultra\$runId\$bid" }
    $wPid = 0
    if ($b.workerPid) { [void][int]::TryParse([string]$b.workerPid, [ref]$wPid) }
    $alive = ($wPid -gt 0) -and ($null -ne (Get-Process -Id $wPid -ErrorAction SilentlyContinue))
    $scs = @($b.scIds)

    $bandLedger = Join-Path $wt '.claude\scratch\ledger.md'
    $pack = Get-BandTodosForBoard -ScIds $scs -BandLedgerPath $bandLedger `
      -MasterLedgerPath $ledger -Alive $alive -BandState ([string]$b.state)
    $todo = @($pack.Todo)
    $active = [string]$pack.ActiveId
    if (-not $active -and $scs.Count) { $active = [string]$scs[0] }
    $activeText = Get-ScDisplayText -ScId $active -TitleMap $titleMap
    if (-not $activeText) { $activeText = $active }

    # Never push status=stalled/queued — ownership treats those as "active dead" corpses.
    # idle = waiting/queued; complete = band finished; running = live pid only.
    $bandResult = Join-Path $wt '.claude\scratch\band-result.json'
    $isDone = ([string]$b.state -eq 'done')
    if (-not $isDone -and (Test-Path -LiteralPath $bandResult)) {
      try {
        $jr = Get-Content -LiteralPath $bandResult -Raw | ConvertFrom-Json
        if ($jr.ok -eq $true -and [string]$jr.bandId -eq $bid) { $isDone = $true }
      } catch {}
    }
    $status = if ($alive) { 'running' }
      elseif ($isDone) { 'complete' }
      else { 'idle' }
    if ($isDone) {
      # force all SC cards done so rings show complete not invader
      for ($ti = 0; $ti -lt $todo.Count; $ti++) {
        $todo[$ti] = @{ id = $todo[$ti].id; text = $todo[$ti].text; state = 'done' }
      }
      $active = $bid
      $activeText = "$bid complete"
    }

    $doneCount = @($todo | Where-Object { $_.state -eq 'done' }).Count
    $ipCount = @($todo | Where-Object { $_.state -eq 'in-progress' }).Count
    $pendCount = @($todo | Where-Object { $_.state -eq 'pending' }).Count

    $body = @{
      sessionId       = $bandSess
      repoPath        = $wt
      primaryRepoPath = $wt
      repoId          = [IO.Path]::GetFileName($RepoDir.TrimEnd('\', '/'))
      branch          = $(if ($b.branch) { [string]$b.branch } else { "ultra/$runId-$bid" })
      status          = $status
      pid             = $(if ($alive) { $wPid } else { 0 })
      runnerPid       = $(if ($alive) { $wPid } else { 0 })
      role            = 'subagent'
      chatLabel       = "SA-$n · $bid"
      ledgerTitle     = "Worker $bid"
      ledgerPath      = $null
      logPath         = $log
      slice           = @{
        id    = $active
        title = $(if ($isDone) { "$bid complete · all SCs done" }
          elseif ($alive) { "$active — $activeText" }
          elseif ($b.startsAfter -and -not $alive) { "$bid queued · next $active — $activeText" }
          else { "$bid waiting · $active — $activeText" })
        state = $(if ($alive) { 'in-progress' } elseif ($isDone) { 'done' } else { 'pending' })
        total = @($s.bands).Count
        index = $n
      }
      counts          = @{
        pending    = $(if ($isDone) { 0 } else { $pendCount })
        done       = $(if ($isDone) { $todo.Count } else { $doneCount })
        inProgress = $(if ($alive) { [Math]::Max(1, $ipCount) } else { 0 })
        blocked    = 0
        standby    = 0
      }
      todo            = $todo
      stats           = @{ engine = $s.engine; engineDisplay = $s.engineDisplay }
    }

    if ($alive -and $cardSamples.Count -lt 4) {
      [void]$cardSamples.Add("$bid/$active=$activeText")
    }

    try {
      if (-not (Test-BoardSessionPresent -SessionId $bandSess)) {
        $null = Assert-BoardSessionRegistered -SessionId $bandSess -RepoPath $wt -Branch $body.branch `
          -LedgerPath '' -LedgerTitle $body.ledgerTitle -RunnerPid $wPid `
          -AllowAutoApprove -RegisterBody $body -Retries 2
      }
      $null = Invoke-BoardApi -Method POST -Path '/api/sessions' -Body $body
    } catch {
      try { $null = Invoke-BoardApi -Method POST -Path "/api/sessions/$bandSess/heartbeat" -Body $body } catch {}
    }
  }

  L "synced run=$runId live=$runningN bands=$(@($s.bands).Count) cards=$($cardSamples -join ' | ')"
}

L "start interval=${IntervalSec}s root=$Root"
while ($true) {
  if (-not (Test-Path -LiteralPath $flag) -and -not (Test-Path -LiteralPath $statePath)) {
    L 'no ultra flag/state — exit'
    break
  }
  try { Sync-Once } catch { L "err $($_.Exception.Message)" }
  if (-not (Test-Path -LiteralPath $flag)) {
    try { Sync-Once } catch {}
    L 'flag gone — exit after final sync'
    break
  }
  Start-Sleep -Seconds $IntervalSec
}
