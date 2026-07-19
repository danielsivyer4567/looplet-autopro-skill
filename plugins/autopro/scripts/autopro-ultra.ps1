# autopro-ultra.ps1 — boring-safe parallel band orchestrator (P0–P2)
#
# Housing only: worktrees, bands, queue, stall detection, board honesty.
# Worker = -Engine auto|claude|codex|gemini|grok (worker-engines.ps1).
# Never merges to main. Never deletes worktrees on stop.
#
# P0: optional board session must stay registered when -RequireBoard
# P1: multi-engine spawn; no $PID; Log never pollutes returns
# P2: stall detector; band-result.json required for "done"

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
  [switch]$NoBandGate,
  [switch]$AllowOllama,
  [switch]$RequireBoard,
  [int]$MaxBandMinutes = 120,
  # Default well above a worst-case `npm run gate` (install+build+test) so a
  # healthy worker mid-large-SC is not killed for simply not committing yet.
  [int]$StallMinutes = 25,
  [int]$GateTimeoutMinutes = 30,
  [string]$Engine = 'auto',
  [string]$Model = '',
  [string]$BoardSessionId = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ultra-band-lib.ps1')
. (Join-Path $PSScriptRoot 'worker-engines.ps1')
. (Join-Path $PSScriptRoot 'showtime-board-gate.ps1')
# Independent per-band gate resolver (same one serial autopro uses to prove an
# epic before it counts as done) — a band must NOT be trusted on self-report.
. (Join-Path $PSScriptRoot 'showtime-final-check.ps1')
# Cross-platform process enumeration + tree-kill (Windows path is the same CIM/taskkill as before).
. (Join-Path $PSScriptRoot 'proc-crossos.ps1')

function Write-UltraLog([string]$RootDir, [string]$Message) {
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $line = "[$ts] $Message"
  Write-Host $line
  $log = Join-Path $RootDir '.claude/scratch/ultra.log'
  $dir = Split-Path $log -Parent
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Add-Content -LiteralPath $log -Value $line
}

if (-not $AllowDangerousSkipPermissions -or -not $IAcceptUnattendedRisk) {
  throw 'Refusing ultra arm without -AllowDangerousSkipPermissions and -IAcceptUnattendedRisk'
}

$RepoDir = (Resolve-Path -LiteralPath $RepoDir).Path
$Root = (Resolve-Path -LiteralPath $Root).Path
$ledger = Join-Path $RepoDir '.claude/scratch/ledger.md'
if (-not (Test-Path -LiteralPath $ledger)) { throw "No ledger at $ledger" }

$flag = Join-Path $Root '.claude/scratch/autopro-on.ultra'
# Collision-proof: seconds-only runId let two same-second arms compute the SAME
# worktree paths, and orchestrator 2's `git worktree remove --force` would
# destroy orchestrator 1's LIVE band tree. Milliseconds + PID make it unique.
$runId = 'u' + (Get-Date -Format 'yyyyMMddHHmmssfff') + '-' + $PID
$statePath = Join-Path $Root '.claude/scratch/ultra-state.json'
$wtRoot = Join-Path (Join-Path $RepoDir '.worktrees-ultra') $runId
$sessionId = if ($BoardSessionId) { $BoardSessionId } else { 'sess_ultra_' + $runId }

function Log([string]$m) { Write-UltraLog -RootDir $Root -Message $m }

Set-Content -LiteralPath $flag -Value $runId -Encoding utf8
Log "==== autopro-ultra P0-P2 start runId=$runId session=$sessionId ===="
Log "repo=$RepoDir bandSize=$BandSize C=$MaxConcurrency split=$SplitMode stallMin=$StallMinutes"

$script:EngineRes = Resolve-AutoproEngine -Requested $Engine -AllowOllama:$AllowOllama
Log "engine=$($script:EngineRes.Engine) display=$($script:EngineRes.Display) (housing — not vendor-locked)"
Log "risk=$(Get-EngineRiskLabel -Engine $script:EngineRes.Engine)"

Push-Location $RepoDir
try {
  $baseSha = (git rev-parse HEAD).Trim()
  $branchName = (git rev-parse --abbrev-ref HEAD 2>$null)
  if (-not $branchName) { $branchName = 'main' }
  $repoTop = (git rev-parse --show-toplevel 2>$null).Trim()
  # Clear any stale worktree admin entries left by a prior manual directory
  # deletion so `git worktree add` cannot trip over ghosts. (worktree prune is
  # allowed for ultra housing; it touches no history.)
  git worktree prune 2>$null | Out-Null
} finally { Pop-Location }
Log "baseSha=$baseSha branch=$branchName"

# The per-band worktrees live INSIDE the working tree (.worktrees-ultra/). If
# that path is not gitignored, `git status` fills with noise and a stray
# `git add -A` can stage embedded git dirs. Assert it once, at the git root.
if ($repoTop) {
  try {
    $gi = Join-Path $repoTop '.gitignore'
    $already = (Test-Path -LiteralPath $gi) -and ((Get-Content -LiteralPath $gi -Raw) -match [regex]::Escape('.worktrees-ultra'))
    if (-not $already) {
      Add-Content -LiteralPath $gi -Value "`n# autopro ultra per-band worktrees — never commit these`n.worktrees-ultra/`n"
      Log "gitignore: added .worktrees-ultra/ to $gi"
    }
  } catch { Log "gitignore assert WARN: $($_.Exception.Message)" }
}

if ($UnblockPaused) {
  Log 'Unblocking [blocked] → [pending]'
  Set-LedgerUnblockAllBlocked -LedgerPath $ledger
}

$runnable = @(Get-RunnableScIds -LedgerPath $ledger)
if ($runnable.Count -eq 0) {
  Log 'No runnable slices — exit 0'
  Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
  exit 0
}
Log ("runnable={0}" -f $runnable.Count)

$bandsPlan = @(Get-UltraBandPlan -ScIds $runnable -BandSize $BandSize -SplitMode $SplitMode)
Log ("bands={0}" -f $bandsPlan.Count)

New-Item -ItemType Directory -Path $wtRoot -Force | Out-Null
$bandStates = [System.Collections.Generic.List[object]]::new()

foreach ($b in $bandsPlan) {
  $branch = "ultra/$runId-$($b.BandId)"
  $path = Join-Path $wtRoot $b.BandId
  $startsAfter = Get-StartsAfterLabel -BandIndex $b.Index -MaxConcurrency $MaxConcurrency -Bands $bandsPlan
  Log "worktree $($b.BandId) → $branch ($($b.ScIds -join ','))"
  Push-Location $RepoDir
  try {
    if (Test-Path -LiteralPath $path) {
      git worktree remove --force $path 2>$null | Out-Null
    }
    $null = git worktree add -b $branch $path $baseSha 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git worktree add failed $($b.BandId)" }
  } finally { Pop-Location }

  $bandScratch = Join-Path $path '.claude/scratch'
  New-Item -ItemType Directory -Path $bandScratch -Force | Out-Null
  $master = Get-Content -LiteralPath $ledger -Raw
  $claimSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$b.ScIds)
  $bandLedger = [regex]::Replace($master, '(?m)^(##\s+(SC-[\w-]+)\s+[—\-]\s+.+?)\s+\[(pending|in-progress|done|blocked)\]\s*$', {
      param($m)
      $id = $m.Groups[2].Value
      $head = $m.Groups[1].Value
      $cur = $m.Groups[3].Value
      if ($claimSet.Contains($id)) {
        if ($cur -eq 'done') { return "$head  [done]" }
        return "$head  [pending]"
      }
      if ($cur -eq 'done') { return "$head  [done]" }
      return "$head  [blocked]"
    })
  $hdr = @"
<!-- ULTRA BAND $($b.BandId) run=$runId engine=$($script:EngineRes.Engine) -->
<!-- CLAIMED: $($b.ScIds -join ', ') -->
<!-- MASTER: $ledger -->
<!-- On complete write band-result.json { ok, bandId, done:[], blocked:[], engine } -->

"@
  [System.IO.File]::WriteAllText((Join-Path $bandScratch 'ledger.md'), ($hdr + $bandLedger))
  Set-Content -LiteralPath (Join-Path $bandScratch "autopro-on.band-$($b.BandId)") -Value $runId -Encoding utf8

  $bandStates.Add([ordered]@{
      bandId         = $b.BandId
      index          = $b.Index
      scIds          = @($b.ScIds)
      branch         = $branch
      worktree       = $path
      state          = 'queued'
      startsAfter    = $startsAfter
      workerPid      = $null
      startedAt      = $null
      lastProgressAt = $null
      lastHeadSha    = $baseSha
      exitCode       = $null
      failReason     = $null
    }) | Out-Null
}

function Save-UltraState {
  $payload = [ordered]@{
    runId            = $runId
    sessionId        = $sessionId
    baseSha          = $baseSha
    repoDir          = $RepoDir
    bandSize         = $BandSize
    maxConcurrency   = $MaxConcurrency
    splitMode        = $SplitMode
    engine           = $script:EngineRes.Engine
    engineDisplay    = $script:EngineRes.Display
    model            = $Model
    stallMinutes     = $StallMinutes
    housing          = 'structure-only'
    updatedAt        = (Get-Date).ToString('o')
    startedAt        = $script:StartedAt
    bands            = @($bandStates)
  }
  ($payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $statePath -Encoding utf8
}

$script:StartedAt = (Get-Date).ToString('o')
Save-UltraState

# P0 board registration (fail-closed when RequireBoard or always try soft)
$boardBody = @{
  sessionId   = $sessionId
  repoPath    = $RepoDir
  repoId      = [IO.Path]::GetFileName($RepoDir.TrimEnd('\', '/'))
  branch      = $branchName
  status      = 'running'
  ledgerPath  = $ledger
  ledgerTitle = (Get-Content $ledger -TotalCount 1) -replace '^#\s*', ''
  logPath     = (Join-Path $Root '.claude/scratch/ultra.log')
  counts      = @{
    pending    = $runnable.Count
    done       = 0
    inProgress = 0
    blocked    = 0
    standby    = 0
  }
  slice       = @{
    id     = $bandsPlan[0].BandId
    title  = "ultra $($bandsPlan[0].BandId)"
    index  = 1
    total  = $bandsPlan.Count
    state  = 'pending'
  }
  stats       = @{
    engine        = $script:EngineRes.Engine
    engineDisplay = $script:EngineRes.Display
    model         = $Model
  }
}
try {
  $gate = Assert-BoardSessionRegistered -SessionId $sessionId -RepoPath $RepoDir `
    -Branch $branchName -LedgerPath $ledger -LedgerTitle $boardBody.ledgerTitle `
    -LogPath $boardBody.logPath -AllowAutoApprove -RegisterBody $boardBody -Retries 4
  if ($gate.ok) {
    Log "BOARD_LANE_OK session=$sessionId healed=$($gate.healed)"
  } else {
    Log "BOARD_LANE_FAIL $($gate.error)"
    if ($RequireBoard) {
      Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
      throw $gate.error
    }
    Log 'BOARD_LANE soft-fail (RequireBoard not set) — continuing with log as truth'
  }
} catch {
  Log "BOARD_LANE exception: $($_.Exception.Message)"
  if ($RequireBoard) {
    Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    throw
  }
}

function Get-BandHeadSha([string]$Worktree) {
  try {
    Push-Location $Worktree
    return (git rev-parse HEAD 2>$null).Trim()
  } catch { return '' }
  finally { Pop-Location }
}

# Test-BandResultOk + Get-BandDoneScIds are defined once in ultra-band-lib.ps1
# (dot-sourced above) so autopro-ultra and ultra-resume share one definition.

# Independent, orchestrator-run gate for a finished band. A band's own
# band-result.json is self-graded and must not be trusted — this re-runs the
# repo's real gate (AUTOPRO_FINAL_CHECK_CMD / scripts/final-check.ps1 / npm run
# gate) inside the band's OWN worktree and requires exit 0. Bounded so a hung
# gate cannot wedge the scheduler forever.
# Returns @{ Ran = bool; Ok = bool; Display = string; ExitCode = int }.
function Invoke-BandGate([string]$Worktree, [int]$TimeoutMinutes) {
  $gate = Resolve-IndependentFinalGate -WorkDir $Worktree
  if ($gate.Kind -eq 'none') {
    # No gate defined in the repo — cannot independently verify. Report not-run
    # so the caller still relies on the cheap commit check.
    return @{ Ran = $false; Ok = $true; Display = 'none'; ExitCode = 0 }
  }
  try {
    $proc = Start-Process -FilePath $gate.Command -ArgumentList $gate.Args `
      -WorkingDirectory $Worktree -WindowStyle Hidden -PassThru
    $timeoutMs = [int]([math]::Max(1, $TimeoutMinutes) * 60000)
    if (-not $proc.WaitForExit($timeoutMs)) {
      try { [void](Stop-ProcessTree -Id $proc.Id) } catch {}
      return @{ Ran = $true; Ok = $false; Display = $gate.Display; ExitCode = 124 }
    }
    return @{ Ran = $true; Ok = ($proc.ExitCode -eq 0); Display = $gate.Display; ExitCode = [int]$proc.ExitCode }
  } catch {
    return @{ Ran = $true; Ok = $false; Display = $gate.Display; ExitCode = -1 }
  }
}

# After a hard tree-kill a git operation may have been interrupted, leaving a
# stale index.lock in the band's private worktree gitdir that would break a
# later resume or manual merge. Best-effort clear it.
function Clear-BandIndexLock([string]$Worktree) {
  try {
    Push-Location $Worktree
    $gitDir = (git rev-parse --git-dir 2>$null).Trim()
    Pop-Location
    if ($gitDir) {
      if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $Worktree $gitDir }
      $lock = Join-Path $gitDir 'index.lock'
      if (Test-Path -LiteralPath $lock) { Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue }
    }
  } catch {}
}

# Verify a pid still belongs to THIS band's worker before trusting "alive" or
# issuing a kill — a recycled pid must not read as alive (masking a finished
# band) or get an unrelated process killed. Matches the run-band.ps1 wrapper.
function Test-BandWorkerAlive([int]$WorkerPid, [string]$Worktree) {
  if ($WorkerPid -le 0) { return $false }
  $proc = Get-Process -Id $WorkerPid -ErrorAction SilentlyContinue
  if (-not $proc) { return $false }
  try {
    $ap = Get-AutoproProcessById -Id $WorkerPid
    if ($ap -and $ap.CommandLine) {
      # The wrapper's command line contains this band's run-band.ps1 path.
      return ([string]$ap.CommandLine -like "*$Worktree*") -or ([string]$ap.CommandLine -like '*run-band.ps1*')
    }
  } catch {}
  # No command-line visibility (identity unknowable) — fall back to bare liveness.
  return $true
}

function Start-BandWorker {
  param($Band)
  $wt = [string]$Band.worktree
  $bid = [string]$Band.bandId
  $branch = [string]$Band.branch
  $ids = @($Band.scIds) -join ', '
  $eng = $script:EngineRes.Engine
  $prompt = @"
You are an AutoPro BAND worker (ultra housing — engine=$eng).
Band: $bid | Branch: $branch | Claimed SCs ONLY: $ids

Rules:
1. Read .claude/scratch/ledger.md in THIS worktree. Process claimed SCs in order; skip [done].
2. Do not implement non-claimed SCs.
3. For each SC: implement, run npm run gate when applicable, commit with SC id in message.
4. Mark finished SCs [done] in THIS worktree's ledger ONLY (.claude/scratch/ledger.md here).
   Do NOT edit any file outside this worktree — in particular do NOT touch the
   master ledger ($ledger). The orchestrator is the single writer of the master
   and reconciles it from your band-result.json. (N bands writing the one master
   file concurrently loses [done] marks — that is why this is forbidden.)
5. Do NOT merge to main. Do NOT delete worktrees.
6. REQUIRED before exit: write .claude/scratch/band-result.json as:
   {"ok":true,"bandId":"$bid","done":["SC-.."],"blocked":[],"engine":"$eng"}
   done[] MUST list exactly the SCs you actually finished + committed. If you
   cannot finish, still write band-result.json with ok:false and blocked reasons.
7. Then stop.

Start with the first incomplete claimed SC and finish the band.
"@

  $scratch = Join-Path $wt '.claude/scratch'
  $promptFile = Join-Path $scratch 'band-prompt.txt'
  [System.IO.File]::WriteAllText($promptFile, $prompt)
  @{ engine = $eng; display = $script:EngineRes.Display; model = $Model } |
    ConvertTo-Json | Set-Content (Join-Path $scratch 'band-engine.json') -Encoding utf8

  # Remove stale result from prior attempt
  $resultPath = Join-Path $scratch 'band-result.json'
  if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath -Force }

  $enginesPs1 = (Join-Path $PSScriptRoot 'worker-engines.ps1') -replace "'", "''"
  $wtEsc = $wt -replace "'", "''"
  $promptEsc = $promptFile -replace "'", "''"
  $engId = $eng -replace "'", "''"
  $modelEsc = ($Model -replace "'", "''")
  $skipLit = if ($AllowDangerousSkipPermissions) { '$true' } else { '$false' }

  $runPs1 = Join-Path $scratch 'run-band.ps1'
  $runBody = @"
`$ErrorActionPreference = 'Continue'
. '$enginesPs1'
Set-Location -LiteralPath '$wtEsc'
`$prompt = Get-Content -LiteralPath '$promptEsc' -Raw
`$out = Join-Path (Get-Location) '.claude/scratch/band-worker.out.log'
`$err = Join-Path (Get-Location) '.claude/scratch/band-worker.err.log'
try {
  `$res = Resolve-EngineBinary -Engine '$engId'
  if (-not `$res.Available) { throw "Engine $engId unavailable: `$(`$res.Hint)" }
  "engine=`$(`$res.Engine) file=`$(`$res.FileName) start=`$(Get-Date -Format o)" | Set-Content -LiteralPath `$out -Encoding utf8
  `$wargs = Build-WorkerArgumentList -Resolution `$res -Prompt `$prompt -WorkDir ((Get-Location).Path) -ModelName '$modelEsc' -SkipPermissions:$skipLit
  `$allArgs = @(`$res.PrefixArgs) + @(`$wargs)
  & `$res.FileName @allArgs 1>>`$out 2>>`$err
  `$code = `$LASTEXITCODE
  # If model forgot band-result.json, leave missing — orchestrator marks failed (P2)
  exit `$code
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
  $proc = Start-Process -FilePath $pwshExe `
    -ArgumentList $argLine `
    -WorkingDirectory $wt `
    -WindowStyle Hidden `
    -PassThru
  if (-not $proc) { throw "Start-Process null for $bid" }
  $workerPid = [int]$proc.Id
  Log "spawn $bid engine=$eng workerPid=$workerPid"
  return $workerPid
}

function Get-BandSliceInfo($Band) {
  # Prefer first SC id for the column so the plate shows SC-08 not just "B01"
  $sc0 = @($Band.scIds) | Select-Object -First 1
  $st = switch ([string]$Band.state) {
    'running' { 'in-progress' }
    'done' { 'done' }
    'failed' { 'blocked' }
    'stalled' { 'blocked' }
    'queued' { 'pending' }
    default { 'pending' }
  }
  $title = if ($Band.state -eq 'queued' -and $Band.startsAfter) {
    "$($Band.bandId) · $($Band.startsAfter)"
  } elseif ($sc0) {
    "$($Band.bandId) · $sc0… ($($Band.scIds.Count) SCs)"
  } else {
    [string]$Band.bandId
  }
  return @{
    id    = $(if ($sc0) { [string]$sc0 } else { [string]$Band.bandId })
    title = $title
    state = $st
    total = $bandStates.Count
    index = ([int]$Band.index + 1)
  }
}

function Sync-BandLaneToBoard {
  <#
    One SA column per band with THAT band's live workerPid.
    Show Time only draws invaders when pid is alive — ultra must not send a dead orch pid.
  #>
  param($Band, [string]$FleetStatus = 'running')
  $bid = [string]$Band.bandId
  $bandSess = "sess_${runId}_${bid}"
  $wPid = 0
  if ($Band.workerPid) { [void][int]::TryParse([string]$Band.workerPid, [ref]$wPid) }
  $alive = ($wPid -gt 0) -and ($null -ne (Get-Process -Id $wPid -ErrorAction SilentlyContinue))

  # Note: status "queued" with pid=0 is treated as corpse by ownership (looksActive).
  # Use idle for waiting bands so the lane stays a projector, not DEAD.
  $laneStatus = switch ([string]$Band.state) {
    'running' { if ($alive) { 'running' } else { 'stalled' } }
    'done' { 'complete' }
    'failed' { 'blocked' }
    'stalled' { 'stalled' }
    'queued' { 'idle' }
    default { if ($alive) { 'running' } else { 'idle' } }
  }

  if (-not $script:TitleMap) {
    $script:TitleMap = Get-LedgerTitleMap -LedgerPath $ledger
  }

  # Use the band WORKTREE as primaryRepoPath so ownership treats each band as its
  # own writer root (Show Time single-writer is per root). Fleet grouping strips
  # .worktrees-ultra so they still share one fleet column.
  $wtPath = [string]$Band.worktree
  # NEVER fall back to $RepoDir: if the worktree is blank, every such band would
  # register the same root and single-writer ownership would collapse them onto
  # one lane, hiding the other bands' invaders (the exact collapse we guard
  # against). Fail this band's board upsert loudly instead.
  if (-not $wtPath) {
    Log "board WARN: band $($Band.bandId) has no worktree — skipping lane (won't collapse bands onto the main repo)"
    return
  }

  $scs = @($Band.scIds)
  $bandLedger = Join-Path $wtPath '.claude/scratch/ledger.md'
  $pack = Get-BandTodosForBoard -ScIds $scs -BandLedgerPath $bandLedger `
    -MasterLedgerPath $ledger -Alive $alive -BandState ([string]$Band.state)
  $todo = @($pack.Todo)
  $activeId = [string]$pack.ActiveId
  if (-not $activeId -and $scs.Count) { $activeId = [string]$scs[0] }
  $activeTitle = Get-ScDisplayText -ScId $activeId -TitleMap $script:TitleMap

  $sliceInfo = Get-BandSliceInfo $Band
  $sliceInfo.id = $activeId
  $sliceInfo.title = $(if ($alive) { "$activeId — $activeTitle" }
    elseif ($Band.startsAfter) { "$bid · $($Band.startsAfter)" }
    else { "$bid · $activeTitle" })
  $sliceInfo.state = $(if ($alive) { 'in-progress' } elseif ($Band.state -eq 'done') { 'done' } else { 'pending' })

  $doneCount = @($todo | Where-Object { $_.state -eq 'done' }).Count
  $pendCount = @($todo | Where-Object { $_.state -eq 'pending' }).Count

  $body = @{
    sessionId       = $bandSess
    repoPath        = $wtPath
    repoId          = [IO.Path]::GetFileName($RepoDir.TrimEnd('\', '/'))
    branch          = [string]$Band.branch
    primaryRepoPath = $wtPath
    status          = $laneStatus
    pid             = $(if ($alive) { $wPid } else { 0 })
    runnerPid       = $(if ($alive) { $wPid } else { 0 })
    # Never attach master ledgerPath — server would replace band todos with all 50 SCs
    ledgerPath      = $null
    ledgerTitle     = "Worker $bid"
    logPath         = (Join-Path $Root '.claude/scratch/ultra.log')
    role            = 'subagent'
    chatLabel       = "SA-$([int]$Band.index + 1) · $bid"
    slice           = $sliceInfo
    counts          = @{
      pending    = $pendCount
      done       = $doneCount
      inProgress = $(if ($Band.state -eq 'running' -and $alive) { 1 } else { 0 })
      blocked    = $(if ($Band.state -match 'fail|stall') { 1 } else { 0 })
      standby    = 0
    }
    todo            = $todo
    stats           = @{
      engine        = $script:EngineRes.Engine
      engineDisplay = $script:EngineRes.Display
      model         = $Model
    }
    sentinelEntry   = @{
      text  = $(if ($Band.state -eq 'queued') { "$bid QUEUED · $($Band.startsAfter)" }
        elseif ($alive) { "$bid coding · $activeId — $activeTitle · pid=$wPid" }
        else { "$bid $($Band.state)" })
      level = 'info'
    }
  }

  # Ensure join approved then upsert session (pid is what draws the invader)
  if (-not (Test-BoardSessionPresent -SessionId $bandSess)) {
    $null = Assert-BoardSessionRegistered -SessionId $bandSess -RepoPath $wtPath `
      -Branch $branchName -LedgerPath '' -LedgerTitle $body.ledgerTitle `
      -LogPath $body.logPath -RunnerPid $wPid -AllowAutoApprove -RegisterBody $body -Retries 3
  }
  try {
    $null = Invoke-BoardApi -Method POST -Path '/api/sessions' -Body $body
  } catch {
    # heartbeat path if session exists
    try {
      $null = Invoke-BoardApi -Method POST -Path "/api/sessions/$bandSess/heartbeat" -Body $body
    } catch {
      Log "band lane $bid board warn: $($_.Exception.Message)"
    }
  }
}

function Update-BoardHeartbeat {
  param([string]$Status = 'running', [string]$ActiveBand = '')
  try {
    # 1) One SA column per band with REAL worker pids (this is what draws invaders)
    foreach ($b in $bandStates) {
      Sync-BandLaneToBoard -Band $b -FleetStatus $Status
    }

    # 2) Fleet/orch head: DESK only (pid 0) — band workers own their own pids/invaders
    $livePids = @()
    $liveBandIds = @()
    foreach ($b in $bandStates) {
      if ($b.state -ne 'running' -or -not $b.workerPid) { continue }
      $wp = 0
      if ([int]::TryParse([string]$b.workerPid, [ref]$wp) -and $wp -gt 0) {
        if (Get-Process -Id $wp -ErrorAction SilentlyContinue) {
          $livePids += $wp
          $liveBandIds += [string]$b.bandId
        }
      }
    }

    if (-not (Test-BoardSessionPresent -SessionId $sessionId)) {
      $boardBody.pid = 0
      $boardBody.role = 'orch'
      $null = Assert-BoardSessionRegistered -SessionId $sessionId -RepoPath $RepoDir `
        -Branch $branchName -LedgerPath '' -AllowAutoApprove -RegisterBody $boardBody -Retries 2
    }

    $running = @($bandStates | Where-Object { $_.state -eq 'running' }).Count
    $queued = @($bandStates | Where-Object { $_.state -eq 'queued' }).Count
    $doneB = @($bandStates | Where-Object { $_.state -eq 'done' }).Count
    $failed = @($bandStates | Where-Object { $_.state -in @('failed', 'blocked', 'stalled') }).Count
    # ORCH head: never send ledgerPath + empty todo — server auto-fills ALL slices
    # from disk (fake SA-1 green stack). Use a single fleet-status card instead.
    $hb = @{
      status      = $Status
      sessionId   = $sessionId
      pid         = 0
      runnerPid   = 0
      role        = 'orch'
      chatLabel   = 'ORCH'
      ledgerTitle = 'OTIS Computer Fluency (full 50)'
      ledgerPath  = $null
      # deliberate non-empty so theater-server will NOT parseLedgerTodos()
      todo        = @(
        @{
          id    = 'FLEET'
          text  = "Fleet · live=$running ($($liveBandIds -join ', ')) queued=$queued doneBands=$doneB · engine=$($script:EngineRes.Engine)"
          state = $(if ($running -gt 0) { 'in-progress' } else { 'pending' })
        }
      )
      counts      = @{
        pending    = $queued
        done       = $doneB
        inProgress = $running
        blocked    = $failed
        standby    = 0
      }
      slice       = @{
        id    = 'ORCH'
        title = "ORCH · live=$running queued=$queued · bands $($liveBandIds -join ',')"
        state = $(if ($running -gt 0) { 'in-progress' } else { 'pending' })
        total = $bandStates.Count
        index = 0
      }
      stats       = @{
        engine        = $script:EngineRes.Engine
        engineDisplay = $script:EngineRes.Display
        model         = $Model
      }
      workers     = @($bandStates | Where-Object { $_.state -eq 'running' } | ForEach-Object {
          @{ bandId = $_.bandId; pid = $_.workerPid; scIds = @($_.scIds) }
        })
    }
    $null = Invoke-BoardApi -Method POST -Path "/api/sessions/$sessionId/heartbeat" -Body $hb
  } catch {
    Log "board heartbeat warn: $($_.Exception.Message)"
  }
}

# --- scheduler ---
$queue = [System.Collections.Generic.Queue[object]]::new()
foreach ($b in $bandStates) { $queue.Enqueue($b) }
$live = [ordered]@{}  # bandId -> workerPid

Log "scheduler start queue=$($queue.Count) C=$MaxConcurrency engine=$($script:EngineRes.Engine)"

while ($true) {
  if (-not (Test-Path -LiteralPath $flag)) {
    Log 'STOP: autopro-on.ultra deleted'
    break
  }

  $now = Get-Date
  $finished = @()

  foreach ($bid in @($live.Keys)) {
    $wPid = [int]$live[$bid]
    $band = $bandStates | Where-Object { $_.bandId -eq $bid } | Select-Object -First 1
    if (-not $band) { $finished += $bid; continue }

    # Identity-checked liveness: a recycled pid must not read as this worker
    # (which would mask a finished band, or later kill an unrelated process).
    $procAlive = Test-BandWorkerAlive -WorkerPid $wPid -Worktree ([string]$band.worktree)

    # Progress = UNION of signals, not commits alone. A single large SC (or a
    # long `npm run gate`) produces ZERO commits for many minutes, so keying
    # stall on HEAD only would kill a healthy worker. The engine streams to
    # band-worker.out.log/err.log continuously while it works — cheap to size.
    $head = Get-BandHeadSha -Worktree ([string]$band.worktree)
    $outLog = Join-Path ([string]$band.worktree) '.claude/scratch/band-worker.out.log'
    $errLog = Join-Path ([string]$band.worktree) '.claude/scratch/band-worker.err.log'
    $outLen = if (Test-Path -LiteralPath $outLog) { (Get-Item -LiteralPath $outLog -ErrorAction SilentlyContinue).Length } else { 0 }
    $errLen = if (Test-Path -LiteralPath $errLog) { (Get-Item -LiteralPath $errLog -ErrorAction SilentlyContinue).Length } else { 0 }
    $sig = "$head|$outLen|$errLen"
    if ($sig -ne [string]$band.lastActivitySig) {
      $band.lastActivitySig = $sig
      $band.lastProgressAt = $now.ToString('o')
      if ($head -and $head -ne [string]$band.lastHeadSha) {
        $band.lastHeadSha = $head
        Log "progress $bid head=$head"
      }
    }

    if (-not $procAlive) {
      $wt = [string]$band.worktree
      # 1) The worker must have written a valid band-result.json (P2).
      if (-not (Test-BandResultOk -Worktree $wt -BandId $bid)) {
        $band.state = 'failed'
        $band.failReason = 'exit-without-band-result.json'
        $band.exitCode = -2
        Log "band FAILED $bid — process exited without valid band-result.json"
        $finished += $bid
        continue
      }
      # 2) Cheap, always-applicable proof of work: HEAD must have advanced past
      # baseSha. A band that says ok:true but never committed produced nothing
      # recoverable (ultra never merges; worktrees are later cleaned).
      if ([string]$band.lastHeadSha -eq [string]$baseSha) {
        $band.state = 'failed'
        $band.failReason = 'done-without-commit'
        $band.exitCode = -3
        Log "band FAILED $bid — ok:true but HEAD never advanced past baseSha (no commit)"
        $finished += $bid
        continue
      }
      # 3) Independent gate: re-run the repo's REAL gate in the band's own
      # worktree. band-result.json is self-graded and must not be trusted.
      if (-not $NoBandGate) {
        $g = Invoke-BandGate -Worktree $wt -TimeoutMinutes $GateTimeoutMinutes
        if ($g.Ran -and -not $g.Ok) {
          $band.state = 'failed'
          $band.failReason = "independent-gate-failed:$($g.Display):exit=$($g.ExitCode)"
          $band.exitCode = -4
          Log "band FAILED $bid — independent gate RED ($($g.Display) exit=$($g.ExitCode))"
          $finished += $bid
          continue
        }
        if ($g.Ran) { Log "band gate GREEN $bid ($($g.Display))" }
        else { Log "band $bid — no independent gate in repo (commit-verified only)" }
      }
      # Accepted: result + commit + gate all passed.
      $band.state = 'done'
      $band.exitCode = 0
      Log "band DONE $bid (result + commit + gate)"
      # Single-writer master reconciliation. The orchestrator (this loop) is
      # the ONLY process that writes the master ledger — bands write only
      # their own worktree ledger. Runs in the single scheduler thread, so
      # these writes are serialized — no lost updates, no concurrent RMW.
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
      $finished += $bid
      continue
    }

    # P2 stall: no new HEAD for StallMinutes after start
    $started = if ($band.startedAt) { [datetime]$band.startedAt } else { $now }
    $lastProg = if ($band.lastProgressAt) { [datetime]$band.lastProgressAt } else { $started }
    $idleMin = ($now - $lastProg).TotalMinutes
    $wallMin = ($now - $started).TotalMinutes

    if ($idleMin -ge $StallMinutes) {
      Log "STALL $bid idleMin=$([math]::Round($idleMin,1)) — killing workerPid=$wPid"
      # Kill the whole tree (children/grandchildren) cross-OS; Windows uses taskkill as before.
      [void](Stop-ProcessTree -Id $wPid)
      Clear-BandIndexLock -Worktree ([string]$band.worktree)
      $band.state = 'stalled'
      $band.failReason = "no-progress-for-${StallMinutes}m"
      $finished += $bid
      continue
    }

    if ($MaxBandMinutes -gt 0 -and $wallMin -ge $MaxBandMinutes) {
      Log "TIMEOUT $bid wallMin=$([math]::Round($wallMin,1)) — killing"
      # Reap the WHOLE tree — the pwsh wrapper's engine + git/node children must
      # not survive as orphans that keep editing the worktree after 'failed'.
      [void](Stop-ProcessTree -Id $wPid)
      Clear-BandIndexLock -Worktree ([string]$band.worktree)
      $band.state = 'failed'
      $band.failReason = "max-band-minutes-$MaxBandMinutes"
      $finished += $bid
    }
  }

  foreach ($bid in $finished) {
    if ($live.Contains($bid)) { $live.Remove($bid) }
  }

  while ($live.Count -lt $MaxConcurrency -and $queue.Count -gt 0) {
    $next = $queue.Dequeue()
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
  $active = @($live.Keys) | Select-Object -First 1
  Update-BoardHeartbeat -ActiveBand ([string]$active)

  if ($live.Count -eq 0 -and $queue.Count -eq 0) {
    Log 'All bands terminal'
    break
  }

  Start-Sleep -Seconds 20
}

$doneN = @($bandStates | Where-Object { $_.state -eq 'done' }).Count
$failN = @($bandStates | Where-Object { $_.state -in @('failed', 'stalled', 'blocked') }).Count
Log "==== ultra end doneBands=$doneN failBands=$failN worktrees=$wtRoot ===="
Log 'Merge to integration manually. Never auto-main. Worktrees kept.'
Update-BoardHeartbeat -Status $(if ($failN -gt 0) { 'blocked' } else { 'complete' })
Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
Write-Host "ULTRA_RUN_ID=$runId"
Write-Host "ULTRA_STATE=$statePath"
Write-Host "ULTRA_WORKTREES=$wtRoot"
if ($failN -gt 0) { exit 2 }
exit 0
