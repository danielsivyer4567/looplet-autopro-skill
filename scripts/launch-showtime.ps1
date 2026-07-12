<#
  launch-showtime.ps1 — arm autopro + open Show Time board (Looplet).

  Creates an isolated git worktree for this session so finish can merge + prune
  without dragging other chats' dirty files into the commit.

  Unattended autonomy is OFF by default. Arming requires both risk switches
  (skip-permissions is otherwise a silent zero-human loop):

    -AllowDangerousSkipPermissions
    -IAcceptUnattendedRisk

  Usage:
    pwsh -File launch-showtime.ps1 -Root <scratch root> -RepoDir <repo with ledger> `
      -AllowDangerousSkipPermissions -IAcceptUnattendedRisk
#>
param(
  [Parameter(Mandatory = $true)][string]$Root,
  [Parameter(Mandatory = $true)][string]$RepoDir,
  [string]$Model = '',
  [switch]$NoBrowser,
  # Headless: skip theater ensure/register/open-board; still arm runner + worktree.
  # Watch via: Get-Content .claude\scratch\autopro.log -Wait
  [switch]$NoShowTime,
  [switch]$NoWorktree,
  [switch]$PushOnFinish,
  # Required together: unattended claude --dangerously-skip-permissions
  [switch]$AllowDangerousSkipPermissions,
  [switch]$IAcceptUnattendedRisk,
  # Escape hatch: merge on model FINAL_CHECK_STATUS=green without npm/script gate
  [switch]$AllowModelOnlyFinalCheck,
  # Default-on fresh verifier after every slice. UI diffs require Playwright
  # screenshot + zero console/page errors; red results get bounded repair runs.
  [switch]$NoSliceVerifier,
  [string]$VerifierModel = '',
  [ValidateRange(0, 3)]
  [int]$VerifierRepairAttempts = 1,
  # base = all mini-branches rejoin the epic branch you armed from (default)
  # main = each ledger session merges into main/master after check
  [ValidateSet('base', 'main')]
  [string]$MergeTarget = 'base',
  [string]$MainBranch = '',
  [int]$StaleAfterMinutes = 30
)

$ErrorActionPreference = 'Stop'
$SkillScripts = $PSScriptRoot
$Runner = Join-Path $SkillScripts 'autopro-runner.ps1'
$Register = Join-Path $SkillScripts 'theater-register.ps1'
$WorktreePs1 = Join-Path $SkillScripts 'showtime-worktree.ps1'
$StatusPs1 = Join-Path $SkillScripts 'showtime-status.ps1'
$StopAutoPro = Join-Path $SkillScripts 'stop-autopro.ps1'
$scratch = Join-Path $Root '.claude\scratch'
$ledger = Join-Path $RepoDir '.claude\scratch\ledger.md'
$sessionStatePath = Join-Path $scratch 'autopro-session.json'

if (-not $AllowDangerousSkipPermissions -or -not $IAcceptUnattendedRisk) {
  throw @'
Refusing to arm unattended autopro without explicit risk acceptance.

A detached runner has no TTY. Without --dangerously-skip-permissions the first
tool call waits forever for a human who never sees the prompt (zombie lane).

Pass BOTH switches to arm:
  -AllowDangerousSkipPermissions
  -IAcceptUnattendedRisk

Example:
  pwsh -NoProfile -File launch-showtime.ps1 -Root <root> -RepoDir <repo> `
    -AllowDangerousSkipPermissions -IAcceptUnattendedRisk
'@
}

if (-not (Test-Path -LiteralPath $ledger)) {
  throw "No ledger at $ledger — run ledger first."
}
$t = Get-Content -LiteralPath $ledger -Raw
if (-not [regex]::IsMatch($t, '(?im)^Approved:\s*yes')) {
  throw 'Ledger not Approved: yes — approve first.'
}

# Independent merge gate must exist (or explicit model-only escape) BEFORE we
# detach a runner that would otherwise burn the whole ledger and then block merge.
. (Join-Path $SkillScripts 'showtime-final-check.ps1')
$preGate = Resolve-IndependentFinalGate -WorkDir $RepoDir
if ($preGate.Kind -eq 'none' -and -not $AllowModelOnlyFinalCheck) {
  throw @"
Refusing to arm: no independent final-check command for this repo.

Detached autopro would run every slice, then block merge with no gate configured.
Configure one of:
  - package.json scripts.gate  (e.g. `"gate`": `"npm test`")
  - scripts/final-check.ps1
  - `$env:AUTOPRO_FINAL_CHECK_CMD
Or pass -AllowModelOnlyFinalCheck to accept model markers alone (risky).

Resolved work dir probe: $RepoDir
"@
}
Write-Output ("INDEPENDENT_GATE kind={0} display={1}" -f $preGate.Kind, $preGate.Display)

New-Item -ItemType Directory -Force -Path $scratch | Out-Null
# Per-session flag: each runner owns its own kill switch, so lanes can't disarm
# each other and a second arm can't silently share a sibling's flag.
$sessionId = 'sess_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$flag = Join-Path $scratch "autopro-on.$sessionId"
$allFlags = @(Get-ChildItem -Path (Join-Path $scratch 'autopro-on*') -File -ErrorAction SilentlyContinue)

function Get-LedgerIdentity([string]$raw) {
  $title = 'ledger'
  $m = [regex]::Match($raw, '(?m)^#\s+(?:Ledger:\s*)?(.+)$')
  if ($m.Success) { $title = $m.Groups[1].Value.Trim() }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
  [pscustomobject]@{ Title = $title; Hash = $hash }
}

$ledgerIdentity = Get-LedgerIdentity $t
$ledgerHash = $ledgerIdentity.Hash
$ledgerTitle = $ledgerIdentity.Title
$priorState = $null
if (Test-Path -LiteralPath $sessionStatePath) {
  try { $priorState = Get-Content -LiteralPath $sessionStatePath -Raw | ConvertFrom-Json } catch { $priorState = $null }
}

if ($allFlags.Count -and $priorState -and $priorState.ledgerHash -and $priorState.ledgerHash -ne $ledgerHash) {
  Write-Output ("NEW_LEDGER_DETECTED oldHash={0} oldTitle={1} newHash={2} newTitle={3}" -f $priorState.ledgerHash, $priorState.ledgerTitle, $ledgerHash, $ledgerTitle)
  $runners = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and
      $_.CommandLine -match 'autopro-runner\.ps1' -and
      $_.CommandLine -like "*$Root*"
    })
  $active = @()
  foreach ($rp in $runners) {
    try {
      $p = Get-Process -Id $rp.ProcessId -ErrorAction Stop
      $ageMin = ((Get-Date) - $p.StartTime).TotalMinutes
      if ($ageMin -lt $StaleAfterMinutes) {
        $active += [pscustomobject]@{ Pid = $rp.ProcessId; AgeMin = [int]$ageMin }
      }
    } catch {}
  }
  if ($active.Count) {
    $active | ForEach-Object { Write-Output ("ACTIVE_OLD_LEDGER_PROCESS pid={0} ageMin={1}" -f $_.Pid, $_.AgeMin) }
    throw "Different ledger is already active. Stop it first or wait until it is stale (threshold ${StaleAfterMinutes}m)."
  }
  Write-Output 'STALE_OLD_LEDGER_CLEANUP starting'
  $stopPs1 = Join-Path $SkillScripts 'stop-autopro.ps1'
  if (Test-Path -LiteralPath $stopPs1) {
    & pwsh -NoProfile -File $stopPs1 -Root $Root -Quiet:$false 2>&1 |
      ForEach-Object { Write-Output "stale> $_" }
  } else {
    $allFlags | Remove-Item -Force -ErrorAction SilentlyContinue
  }
  $allFlags = @(Get-ChildItem -Path (Join-Path $scratch 'autopro-on*') -File -ErrorAction SilentlyContinue)
}

# Arm-guard (same ledger): a flag with a LIVE runner means the ledger is owned.
# The old behavior warned and launched a second runner anyway — that is exactly
# how three runners ended up racing one ledger. Refuse instead.
if ($allFlags.Count) {
  $liveRunners = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'autopro-runner\.ps1' -and $_.CommandLine -like "*$Root*" })
  if ($liveRunners.Count) {
    $allFlags | ForEach-Object { Write-Output ("EXISTING_FLAG={0}" -f $_.Name) }
    $liveRunners | ForEach-Object { Write-Output ("LIVE_RUNNER_PID={0}" -f $_.ProcessId) }
    throw 'A runner is already chasing this ledger. Run stop-autopro.ps1 first if you really want to re-arm.'
  }
  Write-Output ("Removing {0} stale flag(s) with no live runner." -f $allFlags.Count)
  $allFlags | Remove-Item -Force -ErrorAction SilentlyContinue
}
Set-Content -LiteralPath $flag -Value ((Get-Date).ToString('o'))
Remove-Item -LiteralPath (Join-Path $scratch 'auto-chain-paused') -Force -ErrorAction SilentlyContinue

$workDir = $RepoDir
$baseBranch = ''

if (-not $NoWorktree) {
  Write-Output "Creating isolated Show Time worktree (merge target: $MergeTarget)…"
  $wtArgs = @(
    '-NoProfile', '-File', $WorktreePs1,
    '-Action', 'create',
    '-RepoDir', $RepoDir,
    '-SessionId', $sessionId,
    '-LedgerHash', $ledgerHash,
    '-LedgerTitle', $ledgerTitle,
    '-MergeTarget', $MergeTarget
  )
  if ($MainBranch) { $wtArgs += @('-MainBranch', $MainBranch) }
  $wtOut = & pwsh @wtArgs 2>&1
  $wtOut | ForEach-Object { Write-Output "worktree> $_" }
  foreach ($line in $wtOut) {
    if ("$line" -match '^WORKTREE_PATH=(.+)$') { $workDir = $Matches[1].Trim() }
    if ("$line" -match '^BASE=(.+)$') { $baseBranch = $Matches[1].Trim() -replace '^origin/', '' }
  }
  if (-not (Test-Path -LiteralPath $workDir)) {
    throw "Worktree create failed — aborting (refusing shared dirty tree). Re-run with -NoWorktree only if you accept risk."
  }
  # Ledger is usually gitignored — copy into worktree so `work` finds it
  $wtScratch = Join-Path $workDir '.claude\scratch'
  New-Item -ItemType Directory -Force -Path $wtScratch | Out-Null
  Copy-Item -LiteralPath $ledger -Destination (Join-Path $wtScratch 'ledger.md') -Force
  Write-Output "WORKTREE=$workDir"
  Write-Output "BASE_BRANCH=$baseBranch"
  Write-Output "MERGE_TARGET=$MergeTarget"
}

function Resolve-ShowTimeBoardUrl {
  # Single source of truth: server.port after ensure (fallback default 8770).
  $portFile = Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater\server.port'
  if (Test-Path -LiteralPath $portFile) {
    $p = (Get-Content -LiteralPath $portFile -Raw).Trim()
    if ($p -match '^\d+$') { return "http://127.0.0.1:$p/" }
  }
  return 'http://127.0.0.1:8770/'
}

function Get-LoopletCompanionUrl {
  # Returns base URL string if up, else $null. No pipeline noise.
  foreach ($port in 4321, 4322) {
    foreach ($path in @('/ping', '/healthz')) {
      try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port$path" -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop
        if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) {
          return "http://127.0.0.1:$port"
        }
      } catch {}
    }
  }
  return $null
}

function Ensure-LoopletCompanion {
  # Keep a healthy companion; only start when down. Best-effort — never abort arm.
  $alive = Get-LoopletCompanionUrl
  if ($alive) {
    Write-Output "COMPANION_ENSURE=keep $alive"
    return
  }
  Write-Output 'COMPANION_ENSURE=starting'
  $resolve = Join-Path $env:USERPROFILE '.claude\skills\looplet\scripts\resolve-and-run.mjs'
  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($node -and (Test-Path -LiteralPath $resolve)) {
    try {
      # ensure-companion: start only (looplet may kill zombies first — that's OK when offline)
      & $node.Source $resolve ensure-companion 2>&1 | ForEach-Object { Write-Output "companion> $_" }
    } catch {
      Write-Output "companion> resolve-and-run warn: $($_.Exception.Message)"
    }
  } else {
    # Fallback: start companion-server directly from runtime state or well-known path
    $root = $null
    $statePath = Join-Path $env:USERPROFILE '.claude\looplet-runtime.json'
    if (Test-Path -LiteralPath $statePath) {
      try {
        $st = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($st.companionRoot) { $root = [string]$st.companionRoot }
      } catch {}
    }
    if (-not $root) {
      foreach ($c in @(
          $env:LOOPLET_COMPANION_ROOT,
          'C:\LOOPLET\ai-sidebar\companion-server'
        )) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'src\index.js'))) { $root = $c; break }
      }
    }
    if ($root -and $node) {
      try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $node.Source
        $psi.Arguments = "`"$(Join-Path $root 'src\index.js')`""
        $psi.WorkingDirectory = $root
        $psi.UseShellExecute = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        [void][System.Diagnostics.Process]::Start($psi)
        Write-Output "companion> started detached from $root"
      } catch {
        Write-Output "companion> start warn: $($_.Exception.Message)"
      }
    } else {
      Write-Output 'companion> skip (no resolve-and-run / companion root / node)'
    }
  }
  Start-Sleep -Milliseconds 800
  $alive2 = Get-LoopletCompanionUrl
  if ($alive2) {
    Write-Output "COMPANION_ENSURE=up $alive2"
  } else {
    Write-Output 'COMPANION_ENSURE=offline (board still opens in browser)'
  }
}

# Init / refresh living operator status log (gitignored .claude/scratch/SHOWTIME-STATUS.md)
# Do not log a board URL here — port is unknown until ensure; one board URL is emitted later.
if (Test-Path -LiteralPath $StatusPs1) {
  try {
    & pwsh -NoProfile -File $StatusPs1 -RepoDir $RepoDir -Action init -SessionId $sessionId -LedgerPath $ledger -MergeTarget $MergeTarget -WorktreeDir $workDir 2>&1 |
      ForEach-Object { Write-Output "status> $_" }
    & pwsh -NoProfile -File $StatusPs1 -RepoDir $RepoDir -Action event -SessionId $sessionId -Level info -Event "Launch Show Time · merge=$MergeTarget · worktree=$workDir" -LedgerPath $ledger -MergeTarget $MergeTarget -WorktreeDir $workDir 2>&1 |
      ForEach-Object { Write-Output "status> $_" }
    Write-Output "STATUS_LOG=$RepoDir\.claude\scratch\SHOWTIME-STATUS.md"
  } catch {
    Write-Output "status> warn: $($_.Exception.Message)"
  }
}

# --- Production preflight (before new lane appears) ---------------------------
# 1) Ensure board server (skipped when -NoShowTime)
# 2) Stale process check (orphan runners for this root without a live flag)
# 3) Flush undelivered handovers → operator outbox + board folders
# 4) Wipe complete/stale lanes from screen so new arm replaces old work
$boardUrl = $null
if (-not $NoShowTime) {
  Write-Output 'Preflight: ensure Show Time + clear stale board state…'
  & pwsh -NoProfile -File $Register -Action ensure 2>&1 | ForEach-Object { Write-Output "preflight> $_" }

  # Resolve board URL once (after ensure writes server.port). Used for open + TV + SHOWTIME_URL.
  $boardUrl = Resolve-ShowTimeBoardUrl
  if (Test-Path -LiteralPath $StatusPs1) {
    try {
      & pwsh -NoProfile -File $StatusPs1 -RepoDir $RepoDir -Action event -SessionId $sessionId -Level server -Event ("Show Time board: {0}" -f $boardUrl) -LedgerPath $ledger 2>&1 |
        ForEach-Object { Write-Output "status> $_" }
    } catch {}
  }
} else {
  Write-Output 'Preflight: -NoShowTime — skipping theater ensure/register/open'
  if (Test-Path -LiteralPath $StatusPs1) {
    try {
      & pwsh -NoProfile -File $StatusPs1 -RepoDir $RepoDir -Action event -SessionId $sessionId -Level info -Event 'Headless arm (-NoShowTime) · watch autopro.log' -LedgerPath $ledger 2>&1 |
        ForEach-Object { Write-Output "status> $_" }
    } catch {}
  }
}

# Runner scan is informational here; different-ledger stale cleanup above uses scoped stop-autopro.
try {
  $runners = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.CommandLine -and
      $_.CommandLine -match 'autopro-runner\.ps1' -and
      $_.CommandLine -like "*$Root*"
    }
  foreach ($rp in $runners) {
    try {
      $p = Get-Process -Id $rp.ProcessId -ErrorAction Stop
      $ageMin = ((Get-Date) - $p.StartTime).TotalMinutes
      if ($ageMin -ge $StaleAfterMinutes) {
        Write-Output "preflight> stale runner notice PID=$($rp.ProcessId) ageMin=$([int]$ageMin) thresholdMin=$StaleAfterMinutes"
      } else {
        Write-Output "preflight> active runner notice PID=$($rp.ProcessId) ageMin=$([int]$ageMin)"
      }
    } catch {
      Write-Output "preflight> runner PID=$($rp.ProcessId) already gone"
    }
  }
} catch {
  Write-Output "preflight> process scan warn: $($_.Exception.Message)"
}

# Board API preflight: wipe complete/stale sessions + deliver pending handovers
if (-not $NoShowTime) {
  try {
    $portFile = Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater\server.port'
    $port = 8770
    if (Test-Path -LiteralPath $portFile) {
      $p = (Get-Content -LiteralPath $portFile -Raw).Trim()
      if ($p -match '^\d+$') { $port = [int]$p }
    }
    # Join the living board. Never let an automatic arm kill a live lane from
    # another ledger; the server may still prune complete/dead/stale sessions.
    $preBody = @{
      ledgerHash = $ledgerHash
      ledgerTitle = $ledgerTitle
      staleAfterMs = ($StaleAfterMinutes * 60 * 1000)
      killForeignLedgers = $false
      forceKillActiveForeign = $false
    } | ConvertTo-Json -Compress
    $tokFile = Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater\server.token'
    $tok = if (Test-Path -LiteralPath $tokFile) { (Get-Content -LiteralPath $tokFile -Raw).Trim() } else { '' }
    $pre = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/preflight" -Method POST -ContentType 'application/json' -Headers @{ 'X-Showtime-Token' = $tok } -Body $preBody -TimeoutSec 8
    Write-Output ("preflight> wiped={0} handoversFlushed={1} outbox={2}" -f @($pre.wiped).Count, $pre.handoversFlushed, $pre.outbox)
    if ($pre.wiped) {
      foreach ($w in @($pre.wiped)) {
        Write-Output ("preflight> wiped session {0} ({1})" -f $w.sessionId, $w.why)
      }
    }
    if ($pre.kept) {
      foreach ($k in @($pre.kept)) {
        Write-Output ("preflight> kept active old session {0} ({1})" -f $k.sessionId, $k.why)
      }
    }
  } catch {
    Write-Output "preflight> board preflight warn: $($_.Exception.Message)"
  }

  # Ensure Show Time server + register (do not open browser yet — discovery below)
  $regArgs = @(
    '-NoProfile', '-File', $Register,
    '-Action', 'register',
    '-SessionId', $sessionId,
    '-RepoDir', $workDir,
    '-Root', $Root,
    '-LedgerPath', $ledger,
    '-LedgerHash', $ledgerHash,
    '-LedgerTitle', $ledgerTitle,
    '-LogPath', (Join-Path $scratch 'autopro.log'),
    '-Status', 'running'
  )
  & pwsh @regArgs | ForEach-Object { Write-Output $_ }
}

# Detach runner.
# IMPORTANT: RedirectStandard* forces UseShellExecute=false, which keeps the child
# inside the parent job object — hosts that kill the launcher job also kill the
# runner mid-slice (seen 2026-07-11: RUNNER_PID dies, orphaned claude -p).
# UseShellExecute=true + WindowStyle Hidden breaks away from the job. Progress
# still lands in `.claude/scratch/autopro.log` (runner Log() → Add-Content).
# Quote every path/title so () and unicode in ledger titles stay one argv.
function Quote-Arg([string]$s) {
  if ($null -eq $s) { return '""' }
  if ($s -match '[\s"()]') { return '"' + ($s -replace '"', '\"') + '"' }
  return $s
}
$runnerArgParts = @(
  '-NoProfile', '-File', (Quote-Arg $Runner),
  '-Root', (Quote-Arg $Root),
  '-RepoDir', (Quote-Arg $RepoDir),
  '-WorktreeDir', (Quote-Arg $workDir),
  '-SessionId', (Quote-Arg $sessionId),
  '-LedgerHash', (Quote-Arg $ledgerHash),
  '-LedgerTitle', (Quote-Arg $ledgerTitle),
  '-MergeTarget', $MergeTarget,
  '-SkipPermissions',
  '-VerifierRepairAttempts', $VerifierRepairAttempts
)
if ($NoShowTime) { $runnerArgParts += '-NoShowTime' }
if ($Model) { $runnerArgParts += @('-Model', (Quote-Arg $Model)) }
if ($NoWorktree) { $runnerArgParts += '-NoWorktree' }
if ($PushOnFinish) { $runnerArgParts += '-PushOnFinish' }
if ($AllowModelOnlyFinalCheck) { $runnerArgParts += '-AllowModelOnlyFinalCheck' }
if ($NoSliceVerifier) { $runnerArgParts += '-NoSliceVerifier' }
if ($VerifierModel) { $runnerArgParts += @('-VerifierModel', (Quote-Arg $VerifierModel)) }
if ($baseBranch) { $runnerArgParts += @('-BaseBranch', (Quote-Arg $baseBranch)) }
if ($MainBranch) { $runnerArgParts += @('-MainBranch', (Quote-Arg $MainBranch)) }
$runnerArgLine = ($runnerArgParts -join ' ')
$pwshExe = (Get-Command pwsh).Source
# Durable detach: Win32_Process.Create starts outside the parent Job Object.
# Process.Start / Start-Process (even UseShellExecute=true) often stay in the
# launcher job — Grok/CI/agent shells kill the whole job when the launch
# command ends, murdering the runner mid-slice (2026-07-11 twice).
$commandLine = '"{0}" {1}' -f $pwshExe, $runnerArgLine
$runnerPid = 0
try {
  $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine      = $commandLine
    CurrentDirectory = $workDir
  }
  if ($created.ReturnValue -eq 0 -and $created.ProcessId) {
    $runnerPid = [int]$created.ProcessId
    Write-Output ("RUNNER_DETACH=Win32_Process.Create")
  } else {
    Write-Output ("RUNNER_DETACH_WARN return={0} — falling back to cmd start" -f $created.ReturnValue)
  }
} catch {
  Write-Output ("RUNNER_DETACH_WARN {0} — falling back to cmd start" -f $_.Exception.Message)
}
if (-not $runnerPid) {
  # Fallback: cmd start opens a new window group (usually outside the job).
  $cmdLine = '/c start "autopro-{0}" /MIN "{1}" {2}' -f $sessionId, $pwshExe, $runnerArgLine
  $fallback = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdLine -WindowStyle Hidden -PassThru
  Start-Sleep -Milliseconds 1000
  $runnerPid = if ($fallback) { $fallback.Id } else { 0 }
  Write-Output 'RUNNER_DETACH=cmd-start'
}
Start-Sleep -Milliseconds 600
Write-Output ("RUNNER_PID={0}" -f $runnerPid)
Write-Output ("RUNNER_ARGS_LEN={0}" -f $runnerArgLine.Length)
if ($NoShowTime) {
  Write-Output 'HEADLESS=1'
  Write-Output ("WATCH=Get-Content `"{0}`" -Wait -Tail 40" -f (Join-Path $scratch 'autopro.log'))
}

$logPath = Join-Path $scratch 'autopro.log'
try {
  [ordered]@{
    sessionId   = $sessionId
    ledgerHash  = $ledgerHash
    ledgerTitle = $ledgerTitle
    repoDir     = $RepoDir
    workDir     = $workDir
    runnerPid   = $runnerPid
    mergeTarget = $MergeTarget
    state       = 'armed'
    outcome     = 'launching'
    updatedAt   = (Get-Date).ToString('o')
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sessionStatePath -Encoding utf8
  Write-Output "SESSION_STATE=$sessionStatePath"
} catch {
  Write-Output "SESSION_STATE_WARN=$($_.Exception.Message)"
}

# Boot liveness: refuse to leave a "healthy" session if the runner never arms.
# Detects silent-start class (flag on, no armed: line, dead/missing PID).
function Test-PidAliveLocal([int]$procId) {
  if ($procId -le 0) { return $false }
  try { Get-Process -Id $procId -ErrorAction Stop | Out-Null; return $true } catch { return $false }
}
$bootTimeoutSec = 45
$bootDeadline = (Get-Date).AddSeconds($bootTimeoutSec)
$bootArmed = $false
$bootDead = $false
Write-Output ("BOOT_WAIT timeoutSec={0} log={1}" -f $bootTimeoutSec, $logPath)
while ((Get-Date) -lt $bootDeadline) {
  if (Test-Path -LiteralPath $logPath) {
    try {
      $tail = @(Get-Content -LiteralPath $logPath -Tail 120 -ErrorAction SilentlyContinue)
      $sidSeen = $false
      foreach ($line in $tail) {
        $s = [string]$line
        if ($s -match [regex]::Escape("sessionId=$sessionId")) { $sidSeen = $true }
        # Require our session id in the recent window before trusting armed:
        if ($sidSeen -and $s -match 'armed:\s*\d+\s+slices') {
          $bootArmed = $true
          break
        }
      }
      if ($bootArmed) { break }
    } catch {}
  }
  if ($runnerPid -gt 0 -and -not (Test-PidAliveLocal $runnerPid)) {
    $bootDead = $true
    break
  }
  Start-Sleep -Milliseconds 500
}
if ($bootArmed) {
  Write-Output 'BOOT_OK=armed'
  try {
    $st = Get-Content -LiteralPath $sessionStatePath -Raw | ConvertFrom-Json
    $st | Add-Member -NotePropertyName state -NotePropertyValue 'running' -Force
    $st | Add-Member -NotePropertyName outcome -NotePropertyValue 'boot-ok' -Force
    $st | Add-Member -NotePropertyName updatedAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
    $st | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sessionStatePath -Encoding utf8
  } catch {}
} else {
  $why = if ($bootDead) { 'runner-pid-dead' } else { 'armed-timeout' }
  Write-Output ("BOOT_FAIL reason={0}" -f $why)
  try {
    [ordered]@{
      sessionId   = $sessionId
      ledgerHash  = $ledgerHash
      ledgerTitle = $ledgerTitle
      repoDir     = $RepoDir
      workDir     = $workDir
      runnerPid   = $runnerPid
      mergeTarget = $MergeTarget
      state       = 'blocked'
      outcome     = "boot-fail-$why"
      updatedAt   = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sessionStatePath -Encoding utf8
  } catch {}
  Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
  Write-Output "BOOT_DISARMED flag removed — runner never reached armed: within ${bootTimeoutSec}s"
  throw "Autopro boot failed ($why). See $logPath — session not left as healthy running."
}

# Companion + board open — skipped in headless mode
if (-not $NoShowTime) {
  Write-Output 'Ensure Looplet companion (keep if healthy)…'
  try {
    Ensure-LoopletCompanion 2>&1 | ForEach-Object { Write-Output "companion> $_" }
  } catch {
    Write-Output "companion> ensure warn: $($_.Exception.Message)"
  }

  $openBoard = Join-Path $SkillScripts 'showtime-open-board.ps1'
  if (Test-Path -LiteralPath $openBoard) {
    Write-Output "Opening Show Time board in browser: $boardUrl"
    $openArgs = @('-NoProfile', '-File', $openBoard, '-BoardUrl', $boardUrl, '-SessionId', $sessionId)
    if ($NoBrowser) { $openArgs += '-NoBrowser' }
    & pwsh @openArgs 2>&1 | ForEach-Object { Write-Output "open> $_" }
  } elseif (-not $NoBrowser) {
    # Fallback if open-board script missing — still prefer an already-running Chrome/Edge
    Write-Output "Opening Show Time board (fallback, prefer existing browser): $boardUrl"
    $opened = $false
    foreach ($pair in @(
        @{ Exe = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"; Proc = 'chrome' },
        @{ Exe = "${env:LOCALAPPDATA}\Google\Chrome\Application\chrome.exe"; Proc = 'chrome' },
        @{ Exe = "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe"; Proc = 'msedge' }
      )) {
      if (-not (Test-Path -LiteralPath $pair.Exe)) { continue }
      $running = @(Get-Process -Name $pair.Proc -ErrorAction SilentlyContinue)
      try {
        if ($running.Count -gt 0) {
          Start-Process -FilePath $pair.Exe -ArgumentList @('--new-tab', $boardUrl) -ErrorAction Stop
          Write-Output "open> OPENED_IN_EXISTING=$($pair.Proc)"
        } else {
          Start-Process -FilePath $pair.Exe -ArgumentList @($boardUrl) -ErrorAction Stop
          Write-Output "open> OPENED_FRESH=$($pair.Proc)"
        }
        $opened = $true
        break
      } catch {}
    }
    if (-not $opened) {
      try {
        Start-Process $boardUrl
        Write-Output "open> OPENED_PAGE=$boardUrl"
      } catch {
        Write-Output "open> FAILED=$($_.Exception.Message)"
      }
    }
  }
}

# Ledger blurb for the TV card
$ledgerTitle = 'ledger'
try {
  $first = (Get-Content -LiteralPath $ledger -TotalCount 5 | Where-Object { $_ -match '^#\s+' } | Select-Object -First 1)
  if ($first) { $ledgerTitle = ($first -replace '^#\s+', '').Trim() }
} catch {}
$doneN = ([regex]::Matches((Get-Content -LiteralPath $ledger -Raw), '(?m)^##\s+SC-\d+[^\n]*\[done\]')).Count
$pendN = ([regex]::Matches((Get-Content -LiteralPath $ledger -Raw), '(?m)^##\s+SC-\d+[^\n]*\[pending\]')).Count
$ipN = ([regex]::Matches((Get-Content -LiteralPath $ledger -Raw), '(?m)^##\s+SC-\d+[^\n]*\[in-progress\]')).Count
$totalN = $doneN + $pendN + $ipN
$nextSlice = ''
try {
  $m = [regex]::Match((Get-Content -LiteralPath $ledger -Raw), '(?m)^##\s+(SC-\d+)\s+[—–-]\s+(.+?)\s+\[(pending|in-progress)\]')
  if ($m.Success) { $nextSlice = "$($m.Groups[1].Value) $($m.Groups[2].Value)".Trim() }
} catch {}

# TV card — plain monochrome, fixed-width square (no ANSI — hosts strip ESC
# and leave "[94m…[0m" garbage). Outer content width = 40; screen width = 34.
function Tv-Pad([string]$Text, [int]$Width) {
  if ($null -eq $Text) { $Text = '' }
  if ($Text.Length -gt $Width) { return $Text.Substring(0, $Width) }
  $pad = $Width - $Text.Length
  $L = [int][Math]::Floor($pad / 2)
  return ((' ' * $L) + $Text + (' ' * ($pad - $L)))
}
function Tv-Outer([string]$Inner40) {
  # Inner40 must be exactly 40 visible chars
  if ($Inner40.Length -ne 40) { $Inner40 = Tv-Pad $Inner40 40 }
  return ('      ║' + $Inner40 + '║')
}
function Tv-Screen([string]$Inner34) {
  if ($Inner34.Length -ne 34) { $Inner34 = Tv-Pad $Inner34 34 }
  return Tv-Outer ('  │' + $Inner34 + '│  ')
}

Write-Output ''
Write-Output ('      ╔' + ('═' * 40) + '╗')
Write-Output (Tv-Outer (Tv-Pad 'LOOPLET    CHANNEL 3' 40))
Write-Output (Tv-Outer ('  ┌' + ('─' * 34) + '┐  '))
Write-Output (Tv-Screen (Tv-Pad '' 34))
Write-Output (Tv-Screen (Tv-Pad 'ON AIR' 34))
Write-Output (Tv-Screen (Tv-Pad '' 34))
Write-Output (Tv-Screen (Tv-Pad 'S H O W  T I M E' 34))
Write-Output (Tv-Screen (Tv-Pad '' 34))
Write-Output (Tv-Screen (Tv-Pad $boardUrl 34))
Write-Output (Tv-Screen (Tv-Pad '' 34))
Write-Output (Tv-Screen (Tv-Pad 'autonomous ledger  ● LIVE' 34))
Write-Output (Tv-Screen (Tv-Pad '' 34))
Write-Output (Tv-Outer ('  └' + ('─' * 34) + '┘  '))
Write-Output (Tv-Outer (Tv-Pad '(  ) VOL          CHANNEL (  )' 40))
Write-Output (Tv-Outer (Tv-Pad '─────═════─────' 40))
Write-Output ('      ╚' + ('═' * 40) + '╝')
Write-Output (Tv-Pad '▔▔▔▔                   ▔▔▔▔' 48)
Write-Output ''
Write-Output '  SHOWTIME · ON AIR'
Write-Output '  Manual log:'
Write-Output "    Get-Content `"$scratch\autopro.log`" -Wait"
Write-Output ''
Write-Output "SHOWTIME_SESSION=$sessionId"
Write-Output "RUNNER_PID=$runnerPid"
Write-Output "LAUNCHER_PID=$($proc.Id)"
Write-Output "WORK_DIR=$workDir"
Write-Output "SHOWTIME_URL=$boardUrl"
Write-Output "MERGE_TARGET=$MergeTarget"
Write-Output "LEDGER_HASH=$ledgerHash"
Write-Output "LEDGER_TITLE=$ledgerTitle"
Write-Output "SKIP_PERMISSIONS=1"
Write-Output ("SLICE_VERIFIER={0}" -f $(if ($NoSliceVerifier) { 'off' } else { 'on' }))
Write-Output ("VERIFIER_MODEL={0}" -f $(if ($VerifierModel) { $VerifierModel } else { 'worker/default' }))
Write-Output "VERIFIER_REPAIR_ATTEMPTS=$VerifierRepairAttempts"
Write-Output ("ALLOW_MODEL_ONLY_FINAL_CHECK={0}" -f $(if ($AllowModelOnlyFinalCheck) { '1' } else { '0' }))
Write-Output "RISK_ACK=AllowDangerousSkipPermissions+IAcceptUnattendedRisk"
Write-Output "STATUS_LOG=$RepoDir\.claude\scratch\SHOWTIME-STATUS.md"
Write-Output 'CHAT_HINT=Chat only: TV card (board URL once on screen) + manual log (theater/showtime-tv-card.md).'
Write-Output ("Stop: run {0} -Root `"{1}`" or remove .claude\scratch\autopro-on." -f $StopAutoPro, $Root)
