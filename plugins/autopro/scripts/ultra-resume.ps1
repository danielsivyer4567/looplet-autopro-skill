# ultra-resume.ps1 — continue an ultra run after orchestrator death
# Loads ultra-state.json, marks bands done from band-result.json, respawns remaining, keeps board honest.
param(
  [string]$Root = '',
  [string]$RepoDir = '',
  [int]$MaxConcurrency = 0,
  [int]$StallMinutes = 12,
  [switch]$NoBandGate,
  [int]$GateTimeoutMinutes = 30,
  [switch]$AllowDangerousSkipPermissions,
  [switch]$IAcceptUnattendedRisk
)

$ErrorActionPreference = 'Stop'
if (-not $AllowDangerousSkipPermissions -or -not $IAcceptUnattendedRisk) {
  throw 'Refusing ultra resume without -AllowDangerousSkipPermissions and -IAcceptUnattendedRisk'
}

. (Join-Path $PSScriptRoot 'ultra-band-lib.ps1')
. (Join-Path $PSScriptRoot 'worker-engines.ps1')
. (Join-Path $PSScriptRoot 'showtime-board-gate.ps1')
# Re-verify a persisted 'done' rather than trust it: the dead orchestrator may
# have died before it could gate the band.
. (Join-Path $PSScriptRoot 'showtime-final-check.ps1')
. (Join-Path $PSScriptRoot 'proc-crossos.ps1')

if (-not $Root) { $Root = (Get-Location).Path }
if (-not $RepoDir) { $RepoDir = $Root }
$Root = (Resolve-Path -LiteralPath $Root).Path
$RepoDir = (Resolve-Path -LiteralPath $RepoDir).Path
$statePath = Join-Path $Root '.claude\scratch\ultra-state.json'
$flag = Join-Path $Root '.claude\scratch\autopro-on.ultra'
$log = Join-Path $Root '.claude\scratch\ultra.log'
$ledger = Join-Path $RepoDir '.claude\scratch\ledger.md'

function Log([string]$m) {
  $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] RESUME $m"
  Write-Host $line
  Add-Content -LiteralPath $log -Value $line
}

if (-not (Test-Path -LiteralPath $statePath)) { throw "No ultra-state at $statePath" }
$raw = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$runId = [string]$raw.runId
$sessionId = [string]$raw.sessionId
if (-not $sessionId) { $sessionId = "sess_ultra_$runId" }
if ($MaxConcurrency -le 0) { $MaxConcurrency = [int]($raw.maxConcurrency); if ($MaxConcurrency -le 0) { $MaxConcurrency = 4 } }
$StallMinutes = if ($StallMinutes -gt 0) { $StallMinutes } else { [int]$raw.stallMinutes }
if ($StallMinutes -le 0) { $StallMinutes = 12 }
$Model = [string]$raw.model
$baseSha = [string]$raw.baseSha

$script:EngineRes = Resolve-AutoproEngine -Requested $(if ($raw.engine) { [string]$raw.engine } else { 'auto' }) -AllowOllama:$false
Log "==== ultra-resume runId=$runId C=$MaxConcurrency engine=$($script:EngineRes.Engine) ===="

Set-Content -LiteralPath $flag -Value $runId -Encoding utf8
Set-Content -LiteralPath (Join-Path $Root '.claude\scratch\ultra-orchestrator.pid') -Value $PID -Encoding utf8

$bandStates = [System.Collections.Generic.List[object]]::new()
foreach ($b in @($raw.bands)) {
  $bandStates.Add([ordered]@{
      bandId         = [string]$b.bandId
      index          = [int]$b.index
      scIds          = @($b.scIds)
      branch         = [string]$b.branch
      worktree       = [string]$b.worktree
      state          = [string]$b.state
      startsAfter    = $b.startsAfter
      workerPid      = $b.workerPid
      startedAt      = $b.startedAt
      lastProgressAt = $b.lastProgressAt
      lastHeadSha    = [string]$b.lastHeadSha
      exitCode       = $b.exitCode
      failReason     = $b.failReason
    }) | Out-Null
}

function Save-UltraState {
  $payload = [ordered]@{
    runId            = $runId
    sessionId        = $sessionId
    baseSha          = $raw.baseSha
    repoDir          = $RepoDir
    bandSize         = $raw.bandSize
    maxConcurrency   = $MaxConcurrency
    splitMode        = $raw.splitMode
    engine           = $script:EngineRes.Engine
    engineDisplay    = $script:EngineRes.Display
    model            = $Model
    stallMinutes     = $StallMinutes
    housing          = 'structure-only'
    updatedAt        = (Get-Date).ToString('o')
    startedAt        = $raw.startedAt
    resumedAt        = (Get-Date).ToString('o')
    bands            = @($bandStates)
  }
  ($payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $statePath -Encoding utf8
}

# Test-BandResultOk + Get-BandDoneScIds come from ultra-band-lib.ps1 (dot-sourced
# above) — one canonical, fail-closed definition shared with autopro-ultra.

function Get-BandHeadSha([string]$Worktree) {
  if (-not (Test-Path -LiteralPath $Worktree)) { return '' }
  Push-Location $Worktree
  try { return (git rev-parse HEAD 2>$null).Trim() } catch { return '' }
  finally { Pop-Location }
}

function Start-BandWorker {
  param($Band)
  $wt = [string]$Band.worktree
  $bid = [string]$Band.bandId
  $branch = [string]$Band.branch
  $ids = @($Band.scIds) -join ', '
  $eng = $script:EngineRes.Engine
  $prompt = @"
You are an AutoPro BAND worker (ultra housing — engine=$eng) RESUMED.
Band: $bid | Branch: $branch | Claimed SCs ONLY: $ids

Rules:
1. Read .claude/scratch/ledger.md in THIS worktree. Process claimed SCs in order; skip [done].
2. Do not implement non-claimed SCs.
3. For each SC: implement, run npm run gate when applicable, commit with SC id in message.
4. Mark finished SCs [done] in THIS worktree's ledger ONLY (.claude/scratch/ledger.md here).
   Do NOT edit any file outside this worktree — do NOT touch the master ledger
   ($ledger). The orchestrator is the single master writer and reconciles it
   from your band-result.json.
5. Do NOT merge to main. Do NOT delete worktrees.
6. REQUIRED before exit: write .claude/scratch/band-result.json as:
   {"ok":true,"bandId":"$bid","done":["SC-.."],"blocked":[],"engine":"$eng"}
   done[] MUST list exactly the SCs you actually finished + committed.
7. Then stop.

Start with the first incomplete claimed SC and finish the band.
"@
  $scratch = Join-Path $wt '.claude\scratch'
  New-Item -ItemType Directory -Path $scratch -Force | Out-Null
  $promptFile = Join-Path $scratch 'band-prompt.txt'
  [System.IO.File]::WriteAllText($promptFile, $prompt)
  # Keep existing band-result only if we won't re-run; resume always restarts incomplete → clear
  $resultPath = Join-Path $scratch 'band-result.json'
  if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath -Force }

  $enginesPs1 = (Join-Path $PSScriptRoot 'worker-engines.ps1') -replace "'", "''"
  $wtEsc = $wt -replace "'", "''"
  $promptEsc = $promptFile -replace "'", "''"
  $engId = $eng -replace "'", "''"
  $modelEsc = ($Model -replace "'", "''")
  $runPs1 = Join-Path $scratch 'run-band.ps1'
  $runBody = @"
`$ErrorActionPreference = 'Continue'
. '$enginesPs1'
Set-Location -LiteralPath '$wtEsc'
`$prompt = Get-Content -LiteralPath '$promptEsc' -Raw
`$out = Join-Path (Get-Location) '.claude\scratch\band-worker.out.log'
`$err = Join-Path (Get-Location) '.claude\scratch\band-worker.err.log'
try {
  `$res = Resolve-EngineBinary -Engine '$engId'
  if (-not `$res.Available) { throw "Engine $engId unavailable: `$(`$res.Hint)" }
  "RESUME engine=`$(`$res.Engine) start=`$(Get-Date -Format o)" | Set-Content -LiteralPath `$out -Encoding utf8
  `$wargs = Build-WorkerArgumentList -Resolution `$res -Prompt `$prompt -WorkDir ((Get-Location).Path) -ModelName '$modelEsc' -SkipPermissions:`$true
  `$allArgs = @(`$res.PrefixArgs) + @(`$wargs)
  & `$res.FileName @allArgs 1>>`$out 2>>`$err
  exit `$LASTEXITCODE
} catch {
  `$_ | Out-File -FilePath `$err -Append
  exit 1
}
"@
  [System.IO.File]::WriteAllText($runPs1, $runBody)
  $pwshExe = (Get-Command pwsh).Source
  # Start-Process flattens an ArgumentList array on Windows. Quote the script
  # path explicitly so worktree roots containing spaces reach pwsh intact.
  $argLine = '-NoProfile -File "{0}"' -f $runPs1
  $proc = Start-Process -FilePath $pwshExe -ArgumentList $argLine `
    -WorkingDirectory $wt -WindowStyle Hidden -PassThru
  if (-not $proc) { throw "Start-Process null for $bid" }
  Log "spawn $bid engine=$eng workerPid=$($proc.Id)"
  return [int]$proc.Id
}

# --- Reconcile band states from disk ---
$queue = [System.Collections.Generic.Queue[object]]::new()
$live = [ordered]@{}

foreach ($band in $bandStates) {
  $bid = [string]$band.bandId
  $wt = [string]$band.worktree
  $wPid = 0
  if ($band.workerPid) { [void][int]::TryParse([string]$band.workerPid, [ref]$wPid) }
  $alive = ($wPid -gt 0) -and ($null -ne (Get-Process -Id $wPid -ErrorAction SilentlyContinue))

  if (Test-BandResultOk -Worktree $wt -BandId $bid) {
    # Re-verify instead of trusting the persisted ok:true. First the cheap
    # always-true proof: did the band actually commit past baseSha?
    $bandHead = Get-BandHeadSha -Worktree $wt
    if (-not $bandHead -or ($bandHead -eq $baseSha)) {
      $band.state = 'queued'; $band.workerPid = $null; $band.failReason = $null; $band.startedAt = $null
      $queue.Enqueue($band)
      Log "band REQUEUE $bid — ok:true but no commit past baseSha (re-run)"
      continue
    }
    # Then the real gate, in the band's worktree (bounded).
    if (-not $NoBandGate) {
      $gate = Resolve-IndependentFinalGate -WorkDir $wt
      if ($gate.Kind -ne 'none') {
        $gateOk = $false; $gateInfo = "$($gate.Display)"
        try {
          $gp = Start-Process -FilePath $gate.Command -ArgumentList $gate.Args -WorkingDirectory $wt -WindowStyle Hidden -PassThru
          if ($gp.WaitForExit([int]([math]::Max(1, $GateTimeoutMinutes) * 60000))) {
            $gateOk = ($gp.ExitCode -eq 0); $gateInfo = "$($gate.Display) exit=$($gp.ExitCode)"
          } else { try { [void](Stop-ProcessTree -Id $gp.Id) } catch {}; $gateInfo = "$($gate.Display) timeout" }
        } catch { $gateInfo = "$($gate.Display) error" }
        if (-not $gateOk) {
          $band.state = 'queued'; $band.workerPid = $null; $band.failReason = $null; $band.startedAt = $null
          $queue.Enqueue($band)
          Log "band REQUEUE $bid — independent gate RED on resume ($gateInfo)"
          continue
        }
        Log "band gate GREEN $bid on resume ($gateInfo)"
      }
    }
    $band.state = 'done'
    $band.workerPid = $null
    $band.failReason = $null
    $band.exitCode = 0
    Log "band DONE $bid (result + commit + gate)"
    # Single-writer master reconciliation (resume is the sole orchestrator now).
    $doneIds = @(Get-BandDoneScIds -Worktree $wt -ClaimedScIds @($band.scIds))
    if ($doneIds.Count) {
      $map = @{}
      foreach ($sid in $doneIds) { $map[$sid] = 'done' }
      try {
        Set-LedgerSliceStates -LedgerPath $ledger -IdToState $map
        Log "reconcile master: $bid → done [$($doneIds -join ', ')]"
      } catch {
        Log "reconcile master WARN ${bid}: $($_.Exception.Message)"
      }
    }
    continue
  }

  if ($alive) {
    $band.state = 'running'
    $live[$bid] = $wPid
    Log "band LIVE $bid pid=$wPid"
    continue
  }

  # dead/stalled/queued/failed without result → requeue
  $band.state = 'queued'
  $band.workerPid = $null
  $band.failReason = $null
  $band.startedAt = $null
  $queue.Enqueue($band)
  Log "band REQUEUE $bid"
}

Save-UltraState
Log "reconciled live=$($live.Count) queue=$($queue.Count) done=$(@($bandStates | Where-Object { $_.state -eq 'done' }).Count)"

# --- minimal board push (honest status; no stalled corpses) ---
function Push-Board {
  $titleMap = Get-LedgerTitleMap -LedgerPath $ledger
  $livePids = @()
  $liveIds = @()
  foreach ($bid in @($live.Keys)) {
    $wp = [int]$live[$bid]
    if (Get-Process -Id $wp -ErrorAction SilentlyContinue) {
      $livePids += $wp
      $liveIds += $bid
    }
  }
  $orch = @{
    sessionId = $sessionId; repoPath = $RepoDir; primaryRepoPath = $RepoDir; repoId = 'extension'
    branch = 'main'; status = $(if ($livePids.Count) { 'running' } else { 'idle' })
    pid = 0; runnerPid = 0; role = 'orch'; chatLabel = 'ORCH'
    ledgerTitle = 'OTIS Computer Fluency (full 50)'; ledgerPath = $null; logPath = $log
    slice = @{ id = 'ORCH'; title = "ORCH · resume live=$($livePids.Count) ($($liveIds -join ', '))"; state = $(if ($livePids.Count) { 'in-progress' } else { 'pending' }); total = $bandStates.Count; index = 0 }
    counts = @{
      pending = @($bandStates | Where-Object { $_.state -eq 'queued' }).Count
      done = @($bandStates | Where-Object { $_.state -eq 'done' }).Count
      inProgress = $livePids.Count
      blocked = @($bandStates | Where-Object { $_.state -match 'fail|stall' }).Count
      standby = 0
    }
    todo = @(@{ id = 'FLEET'; text = "RESUME live=$($livePids.Count) · queued=$(@($bandStates|? state -eq 'queued').Count) · done=$(@($bandStates|? state -eq 'done').Count)"; state = $(if ($livePids.Count) { 'in-progress' } else { 'pending' }) })
    stats = @{ engine = $script:EngineRes.Engine; engineDisplay = $script:EngineRes.Display }
  }
  try { $null = Invoke-BoardApi -Method POST -Path '/api/sessions' -Body $orch } catch {}

  $n = 0
  foreach ($band in $bandStates) {
    $n++
    $bid = [string]$band.bandId
    $wt = [string]$band.worktree
    $wPid = 0
    if ($band.workerPid) { [void][int]::TryParse([string]$band.workerPid, [ref]$wPid) }
    $alive = ($wPid -gt 0) -and ($null -ne (Get-Process -Id $wPid -ErrorAction SilentlyContinue))
    $pack = Get-BandTodosForBoard -ScIds @($band.scIds) -BandLedgerPath (Join-Path $wt '.claude\scratch\ledger.md') `
      -MasterLedgerPath $ledger -Alive $alive -BandState ([string]$band.state)
    $active = [string]$pack.ActiveId
    $title = Get-ScDisplayText -ScId $active -TitleMap $titleMap
    # honest board status: never "stalled" (that painted Corpse/DEAD). Use idle/complete/running.
    $status = if ($band.state -eq 'done') { 'complete' }
      elseif ($alive) { 'running' }
      elseif ($band.state -eq 'queued') { 'idle' }
      else { 'idle' }
    $todo = @($pack.Todo)
    if ($band.state -eq 'done') {
      $todo = @($band.scIds | ForEach-Object {
          @{ id = [string]$_; text = (Get-ScDisplayText -ScId $_ -TitleMap $titleMap); state = 'done' }
        })
    }
    $body = @{
      sessionId = "sess_${runId}_${bid}"; repoPath = $wt; primaryRepoPath = $wt; repoId = 'extension'
      branch = [string]$band.branch; status = $status
      pid = $(if ($alive) { $wPid } else { 0 }); runnerPid = $(if ($alive) { $wPid } else { 0 })
      role = 'subagent'; chatLabel = "SA-$n · $bid"; ledgerTitle = "Worker $bid"; ledgerPath = $null; logPath = $log
      slice = @{
        id = $(if ($band.state -eq 'done') { $bid } else { $active })
        title = $(if ($band.state -eq 'done') { "$bid complete" }
          elseif ($alive) { "$active — $title" }
          elseif ($band.state -eq 'queued') { "$bid queued — next: $active $title" }
          else { "$bid idle — $active $title" })
        state = $(if ($band.state -eq 'done') { 'done' } elseif ($alive) { 'in-progress' } else { 'pending' })
        total = $bandStates.Count; index = $n
      }
      counts = @{
        pending = @($todo | Where-Object { $_.state -eq 'pending' }).Count
        done = @($todo | Where-Object { $_.state -eq 'done' }).Count
        inProgress = $(if ($alive) { 1 } else { 0 })
        blocked = 0; standby = 0
      }
      todo = $todo
      stats = @{ engine = $script:EngineRes.Engine; engineDisplay = $script:EngineRes.Display }
    }
    try {
      if (-not (Test-BoardSessionPresent -SessionId $body.sessionId)) {
        $null = Assert-BoardSessionRegistered -SessionId $body.sessionId -RepoPath $wt -Branch $body.branch `
          -LedgerPath '' -LedgerTitle $body.ledgerTitle -RunnerPid $wPid -AllowAutoApprove -RegisterBody $body -Retries 2
      }
      $null = Invoke-BoardApi -Method POST -Path '/api/sessions' -Body $body
    } catch {
      try { $null = Invoke-BoardApi -Method POST -Path "/api/sessions/$($body.sessionId)/heartbeat" -Body $body } catch {}
    }
  }
  Log "board push live=$($livePids.Count) ($($liveIds -join ','))"
}

# --- scheduler ---
Log "scheduler resume queue=$($queue.Count) live=$($live.Count)"
Push-Board

while ($true) {
  if (-not (Test-Path -LiteralPath $flag)) {
    Log 'STOP: flag removed'
    break
  }
  $now = Get-Date
  $finished = @()

  foreach ($bid in @($live.Keys)) {
    $wPid = [int]$live[$bid]
    $band = $bandStates | Where-Object { $_.bandId -eq $bid } | Select-Object -First 1
    if (-not $band) { $finished += $bid; continue }
    $procAlive = $null -ne (Get-Process -Id $wPid -ErrorAction SilentlyContinue)
    $head = Get-BandHeadSha -Worktree ([string]$band.worktree)
    if ($head -and $head -ne [string]$band.lastHeadSha) {
      $band.lastHeadSha = $head
      $band.lastProgressAt = $now.ToString('o')
      Log "progress $bid head=$head"
    }
    if (-not $procAlive) {
      if (Test-BandResultOk -Worktree ([string]$band.worktree) -BandId $bid) {
        $band.state = 'done'; $band.exitCode = 0; $band.workerPid = $null
        Log "band DONE $bid (result ok)"
      } else {
        $band.state = 'failed'; $band.failReason = 'exit-without-band-result.json'; $band.workerPid = $null
        Log "band FAILED $bid — exit without band-result"
      }
      $finished += $bid
      continue
    }
    $started = if ($band.startedAt) { [datetime]$band.startedAt } else { $now }
    $lastProg = if ($band.lastProgressAt) { [datetime]$band.lastProgressAt } else { $started }
    if (($now - $lastProg).TotalMinutes -ge $StallMinutes) {
      Log "STALL $bid — kill $wPid"
      try { Stop-Process -Id $wPid -Force -ErrorAction SilentlyContinue } catch {}
      $band.state = 'queued'  # requeue instead of terminal stall so fleet can recover
      $band.workerPid = $null
      $band.failReason = "stall-${StallMinutes}m-requeued"
      $queue.Enqueue($band)
      $finished += $bid
    }
  }
  foreach ($bid in $finished) { if ($live.Contains($bid)) { $live.Remove($bid) } }

  while ($live.Count -lt $MaxConcurrency -and $queue.Count -gt 0) {
    $next = $queue.Dequeue()
    if ([string]$next.state -eq 'done') { continue }
    try {
      $wp = Start-BandWorker -Band $next
      $next.state = 'running'
      $next.workerPid = $wp
      $next.startedAt = $now.ToString('o')
      $next.lastProgressAt = $now.ToString('o')
      $next.lastHeadSha = Get-BandHeadSha -Worktree ([string]$next.worktree)
      $live[[string]$next.bandId] = $wp
      Log "live: $($live.Keys -join ', ')"
    } catch {
      Log "ERROR spawn $($next.bandId): $($_.Exception.Message)"
      $next.state = 'failed'
      $next.failReason = $_.Exception.Message
    }
  }

  Save-UltraState
  try { Push-Board } catch { Log "board warn $($_.Exception.Message)" }

  if ($live.Count -eq 0 -and $queue.Count -eq 0) {
    Log 'All bands terminal'
    break
  }
  Start-Sleep -Seconds 20
}

$doneN = @($bandStates | Where-Object { $_.state -eq 'done' }).Count
$failN = @($bandStates | Where-Object { $_.state -eq 'failed' }).Count
Log "==== resume end doneBands=$doneN failBands=$failN ===="
Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
exit $(if ($failN -gt 0) { 2 } else { 0 })
