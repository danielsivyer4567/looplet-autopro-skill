<#
  launch-showtime.ps1 — arm autopro + open Show Time board (Looplet).

  Show Time has NO git authority: it creates no worktree, no branch, and never
  commits, merges, or prunes. It arms the runner and opens the board. Sessions
  run in the repo on the branch the operator already checked out; the worker's
  own `work` skill owns every commit.

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
  # Worker engine: auto (default) | claude | codex | gemini | grok | ollama
  [string]$Engine = 'auto',
  [string]$VerifierEngine = '',
  [switch]$AllowOllama,
  [switch]$NoBrowser,
  # Headless: skip theater ensure/register/open-board; still arm the runner.
  # Watch via: Get-Content .claude/scratch/autopro.log -Wait
  [switch]$NoShowTime,
  # Required together: unattended worker risk (engine-specific skip/yolo/bypass flags)
  [switch]$AllowDangerousSkipPermissions,
  [switch]$IAcceptUnattendedRisk,
  # Escape hatch: accept model FINAL_CHECK_STATUS=green without npm/script gate
  [switch]$AllowModelOnlyFinalCheck,
  # Default-on fresh verifier after every slice. UI diffs require Playwright
  # screenshot + zero console/page errors; red results get bounded repair runs.
  [switch]$NoSliceVerifier,
  [string]$VerifierModel = '',
  [ValidateRange(0, 3)]
  [int]$VerifierRepairAttempts = 1,
  # Kill hung worker processes after N minutes (0 = no wall-clock kill; still use stall alarm)
  [ValidateRange(0, 480)]
  [int]$MaxSliceMinutes = 90,
  [int]$StaleAfterMinutes = 30,
  # Detach autopro-watch.ps1 so needs-you / chat-inbox events print without a second manual terminal.
  # Default ON: this is the bridge that keeps the human in the loop after the arming chat stops.
  [switch]$NoWatch
)

$ErrorActionPreference = 'Stop'
$SkillScripts = $PSScriptRoot
$Runner = Join-Path $SkillScripts 'autopro-runner.ps1'
$Register = Join-Path $SkillScripts 'theater-register.ps1'
$StatusPs1 = Join-Path $SkillScripts 'showtime-status.ps1'
$StopAutoPro = Join-Path $SkillScripts 'stop-autopro.ps1'
$scratch = Join-Path $Root '.claude/scratch'
$ledger = Join-Path $RepoDir '.claude/scratch/ledger.md'
$sessionStatePath = Join-Path $scratch 'autopro-session.json'

. (Join-Path $SkillScripts 'worker-engines.ps1')
# Cross-platform process enumeration (Windows path is the same CIM query as before).
. (Join-Path $SkillScripts 'proc-crossos.ps1')

if (-not $AllowDangerousSkipPermissions -or -not $IAcceptUnattendedRisk) {
  throw @'
Refusing to arm unattended autopro without explicit risk acceptance.

A detached runner has no TTY. Without engine unattended flags (Claude skip-permissions,
Codex bypass-approvals, Gemini yolo, Grok always-approve) the first tool call waits
forever for a human who never sees the prompt (zombie lane).

Pass BOTH switches to arm:
  -AllowDangerousSkipPermissions
  -IAcceptUnattendedRisk

Example (auto-pick first available engine: claude → codex → gemini → grok):
  pwsh -NoProfile -File launch-showtime.ps1 -Root <root> -RepoDir <repo> `
    -AllowDangerousSkipPermissions -IAcceptUnattendedRisk

Pin an engine:
  … -Engine codex -Model o3
  … -Engine gemini
  … -Engine grok
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

# Engine preflight BEFORE arming — fail fast with install hints (prompt-and-play)
$allEngines = Get-AllEngineResolutions
Write-Output (Format-EnginePreflightReport -Resolutions $allEngines)
try {
  $resolvedEngine = Resolve-AutoproEngine -Requested $Engine -AllowOllama:$AllowOllama
} catch {
  throw @"
ENGINE_PREFLIGHT_FAILED: $($_.Exception.Message)

Run doctor for a full report:
  pwsh -NoProfile -File `"$SkillScripts\autopro-doctor.ps1`" -RepoDir `"$RepoDir`"
"@
}
if ($VerifierEngine -and $VerifierEngine.Trim()) {
  try {
    $null = Resolve-AutoproEngine -Requested $VerifierEngine.Trim() -AllowOllama:$AllowOllama
  } catch {
    throw "VERIFIER_ENGINE_PREFLIGHT_FAILED: $($_.Exception.Message)"
  }
}
# Honor env verifier/model when flags empty (prompt-and-play defaults)
if (-not $Model -and $env:AUTOPRO_MODEL) { $Model = $env:AUTOPRO_MODEL.Trim() }
if (-not $VerifierEngine -and $env:AUTOPRO_VERIFIER_ENGINE) { $VerifierEngine = $env:AUTOPRO_VERIFIER_ENGINE.Trim() }
if (-not $VerifierModel -and $env:AUTOPRO_VERIFIER_MODEL) { $VerifierModel = $env:AUTOPRO_VERIFIER_MODEL.Trim() }

Write-Output ("ENGINE_SELECTED={0}" -f $resolvedEngine.Engine)
Write-Output ("ENGINE_DISPLAY={0}" -f $resolvedEngine.Display)
Write-Output ("ENGINE_RISK={0}" -f (Get-EngineRiskLabel -Engine $resolvedEngine.Engine))
if ($Model) { Write-Output ("MODEL={0}" -f $Model) }
if ($VerifierEngine) { Write-Output ("VERIFIER_ENGINE={0}" -f $VerifierEngine) }
if ($MaxSliceMinutes -gt 0) { Write-Output ("MAX_SLICE_MINUTES={0}" -f $MaxSliceMinutes) }

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
  $runners = @(Get-AutoproProcessList -Names @('pwsh', 'powershell') |
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
  $liveRunners = @(Get-AutoproProcessList -Names @('pwsh', 'powershell') |
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

# Show Time has NO git authority. The session runs in the repo itself, on
# whatever branch the operator already checked out. No worktree is created, no
# branch is minted, nothing is merged or pruned. Work cannot be stranded in a
# tree that only `finish` knows how to bring home, because there is no `finish`.
Write-Output "WORKDIR=$RepoDir (in-place — Show Time creates no worktree or branch)"

function Resolve-ShowTimeBoardUrl {
  # Single source of truth: server.port after ensure (fallback default 8770).
  $portFile = Join-Path ($env:USERPROFILE ?? $HOME) '.claude/scratch/autopro-theater/server.port'
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
  $resolve = Join-Path ($env:USERPROFILE ?? $HOME) '.claude/skills/looplet/scripts/resolve-and-run.mjs'
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
    $statePath = Join-Path ($env:USERPROFILE ?? $HOME) '.claude/looplet-runtime.json'
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
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'src/index.js'))) { $root = $c; break }
      }
    }
    if ($root -and $node) {
      try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $node.Source
        $psi.Arguments = "`"$(Join-Path $root 'src/index.js')`""
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
    & pwsh -NoProfile -File $StatusPs1 -RepoDir $RepoDir -Action init -SessionId $sessionId -LedgerPath $ledger 2>&1 |
      ForEach-Object { Write-Output "status> $_" }
    & pwsh -NoProfile -File $StatusPs1 -RepoDir $RepoDir -Action event -SessionId $sessionId -Level info -Event "Launch Show Time · repo=$RepoDir · no git authority" -LedgerPath $ledger 2>&1 |
      ForEach-Object { Write-Output "status> $_" }
    Write-Output "STATUS_LOG=$RepoDir\.claude/scratch/SHOWTIME-STATUS.md"
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
  # Filtered enum (Windows CIM has OperationTimeoutSec inside the helper — bare enums hang on busy WMI).
  $runners = Get-AutoproProcessList -Names @('pwsh', 'powershell') |
    Where-Object {
      $_.CommandLine -and
      $_.CommandLine -match 'autopro-runner\.ps1' -and
      $_.CommandLine -like "*$Root*"
    }
  foreach ($rp in @($runners)) {
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
    $portFile = Join-Path ($env:USERPROFILE ?? $HOME) '.claude/scratch/autopro-theater/server.port'
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
    $tokFile = Join-Path ($env:USERPROFILE ?? $HOME) '.claude/scratch/autopro-theater/server.token'
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

  # Ensure Show Time server + register (do not open browser yet — discovery below).
  # OpenRegister: risk switches already accepted — skip interactive join wait so
  # prompt-and-play arms do not sit on "Approve on board" for 20s+ (and never hang).
  Write-Output 'Preflight: register lane (OpenRegister · unattended risk accepted)…'
  $regArgs = @(
    '-NoProfile', '-File', $Register,
    '-Action', 'register',
    '-OpenRegister',
    '-SessionId', $sessionId,
    '-RepoDir', $RepoDir,
    '-Root', $Root,
    '-LedgerPath', $ledger,
    '-LedgerHash', $ledgerHash,
    '-LedgerTitle', $ledgerTitle,
    '-LogPath', (Join-Path $scratch 'autopro.log'),
    '-Status', 'running',
    '-Engine', $resolvedEngine.Engine
  )
  if ($Model) { $regArgs += @('-Model', $Model) }
  if ($VerifierEngine) { $regArgs += @('-VerifierEngine', $VerifierEngine) }
  if ($VerifierModel) { $regArgs += @('-VerifierModel', $VerifierModel) }
  $regOut = @(& pwsh @regArgs 2>&1)
  $regOut | ForEach-Object { Write-Output $_ }
  $regText = ($regOut | ForEach-Object { "$_" }) -join "`n"
  if ($regText -match 'BOARD_GATE_FAIL=') {
    throw "Show Time board gate failed during register — refusing to arm (UI would lie). See BOARD_GATE_FAIL above."
  }
  # P0 double-check: session must be on the board before we detach the runner
  . (Join-Path $SkillScripts 'showtime-board-gate.ps1')
  $gateBranch = 'main'
  try {
    Push-Location $RepoDir
    $b = ("$(git rev-parse --abbrev-ref HEAD 2>$null)").Trim()
    if ($b) { $gateBranch = $b }
  } catch {} finally { Pop-Location }
  $boardGate = Assert-BoardSessionRegistered -SessionId $sessionId -RepoPath $RepoDir `
    -Branch $gateBranch -LedgerPath $ledger -LedgerTitle $ledgerTitle -LedgerHash $ledgerHash `
    -LogPath (Join-Path $scratch 'autopro.log') -AllowAutoApprove -Retries 3
  if (-not $boardGate.ok) {
    throw $boardGate.error
  }
  Write-Output ("BOARD_LANE_OK session={0} healed={1}" -f $sessionId, $(if ($boardGate.healed) { 'true' } else { 'false' }))
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
  '-SessionId', (Quote-Arg $sessionId),
  '-LedgerHash', (Quote-Arg $ledgerHash),
  '-LedgerTitle', (Quote-Arg $ledgerTitle),
  '-SkipPermissions',
  '-VerifierRepairAttempts', $VerifierRepairAttempts
)
if ($NoShowTime) { $runnerArgParts += '-NoShowTime' }
if ($Model) { $runnerArgParts += @('-Model', (Quote-Arg $Model)) }
# Pass resolved engine id (not "auto") so runner doesn't re-roll if PATH changes mid-flight
$runnerArgParts += @('-Engine', (Quote-Arg $resolvedEngine.Engine))
if ($VerifierEngine) { $runnerArgParts += @('-VerifierEngine', (Quote-Arg $VerifierEngine)) }
if ($AllowOllama) { $runnerArgParts += '-AllowOllama' }
if ($AllowModelOnlyFinalCheck) { $runnerArgParts += '-AllowModelOnlyFinalCheck' }
if ($NoSliceVerifier) { $runnerArgParts += '-NoSliceVerifier' }
if ($VerifierModel) { $runnerArgParts += @('-VerifierModel', (Quote-Arg $VerifierModel)) }
if ($MaxSliceMinutes -gt 0) { $runnerArgParts += @('-MaxSliceMinutes', "$MaxSliceMinutes") }
$runnerArgLine = ($runnerArgParts -join ' ')
$pwshExe = (Get-Command pwsh).Source
# Durable detach: Win32_Process.Create starts outside the parent Job Object.
# Process.Start / Start-Process (even UseShellExecute=true) often stay in the
# launcher job — Grok/CI/agent shells kill the whole job when the launch
# command ends, murdering the runner mid-slice (2026-07-11 twice).
$commandLine = '"{0}" {1}' -f $pwshExe, $runnerArgLine
$runnerPid = 0
try {
  $created = Start-DetachedProcess -CommandLine $commandLine -CurrentDirectory $RepoDir
  if ($created.ReturnValue -eq 0 -and $created.ProcessId) {
    $runnerPid = [int]$created.ProcessId
    Write-Output ("RUNNER_DETACH={0}" -f $created.How)
  } else {
    Write-Output ("RUNNER_DETACH_WARN return={0} — falling back to cmd start" -f $created.ReturnValue)
  }
} catch {
  Write-Output ("RUNNER_DETACH_WARN {0} — falling back to cmd start" -f $_.Exception.Message)
}
if (-not $runnerPid) {
  # Fallback: cmd start opens a new window group (usually outside the job).
  $cmdLine = '/c start "autopro-{0}" /MIN "{1}" {2}' -f $sessionId, $pwshExe, $runnerArgLine
  $null = Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdLine -WindowStyle Hidden -PassThru
  Write-Output 'RUNNER_DETACH=cmd-start'
  # Never record cmd.exe's PID: cmd exits the moment `start` has spawned the
  # pwsh window, so the boot loop's dead-PID check would deterministically
  # BOOT_FAIL (reason=runner-pid-dead). Resolve the REAL runner PID by
  # commandline (autopro-runner.ps1 + this sessionId) instead.
  $resolveDeadline = (Get-Date).AddSeconds(10)
  while ((Get-Date) -lt $resolveDeadline -and -not $runnerPid) {
    Start-Sleep -Milliseconds 500
    try {
      $cand = Get-AutoproProcessList -Names @('pwsh', 'powershell') |
        Where-Object {
          $_.CommandLine -and
          $_.CommandLine -match 'autopro-runner\.ps1' -and
          $_.CommandLine -match [regex]::Escape($sessionId)
        } | Select-Object -First 1
      if ($cand) { $runnerPid = [int]$cand.ProcessId }
    } catch {}
  }
  if (-not $runnerPid) {
    # Unknown PID (0) is honest: the boot check then relies on the armed: log
    # line alone instead of a false dead-PID verdict.
    Write-Output 'RUNNER_PID_UNRESOLVED=cmd-start spawned but runner pwsh not found yet'
  }
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
    runnerPid   = $runnerPid
    engine      = $resolvedEngine.Engine
    engineDisplay = $resolvedEngine.Display
    model       = $Model
    state       = 'armed'
    outcome     = 'launching'
    updatedAt   = (Get-Date).ToString('o')
  } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sessionStatePath -Encoding utf8
  Write-Output "SESSION_STATE=$sessionStatePath"
} catch {
  Write-Output "SESSION_STATE_WARN=$($_.Exception.Message)"
}
try {
  $null = Save-EngineChoice -ScratchDir $scratch -Engine $resolvedEngine.Engine -Model $Model `
    -SessionId $sessionId -Display $resolvedEngine.Display
} catch {}

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
      runnerPid   = $runnerPid
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
$engTv = ("engine {0}" -f $resolvedEngine.Engine)
if ($Model) { $engTv = ("{0} · {1}" -f $engTv, $Model) }
if ($engTv.Length -gt 34) { $engTv = $engTv.Substring(0, 34) }
Write-Output (Tv-Screen (Tv-Pad $engTv 34))
Write-Output (Tv-Screen (Tv-Pad '' 34))
Write-Output (Tv-Outer ('  └' + ('─' * 34) + '┘  '))
Write-Output (Tv-Outer (Tv-Pad '(  ) VOL          CHANNEL (  )' 40))
Write-Output (Tv-Outer (Tv-Pad '─────═════─────' 40))
Write-Output ('      ╚' + ('═' * 40) + '╝')
Write-Output (Tv-Pad '▔▔▔▔                   ▔▔▔▔' 48)
Write-Output ''
Write-Output '  SHOWTIME · ON AIR'
Write-Output '  Manual log:'
Write-Output "    Get-Content `"$scratch/autopro.log`" -Wait"
Write-Output '  Needs-you watch (chat bridge — use if watch was not detached):'
Write-Output "    pwsh -NoProfile -File `"$SkillScripts/autopro-watch.ps1`" -Root `"$Root`" -UntilDisarmed"
Write-Output ''

# Start chat-bridge watcher in a minimized console so blocked/kickstart/complete
# cannot be silent after the arming chat stops. Prefer a real window (human can
# alt-tab); fall back to job-detached if Start-Process fails.
$watchPid = 0
$WatchPs1 = Join-Path $SkillScripts 'autopro-watch.ps1'
if (-not $NoWatch -and (Test-Path -LiteralPath $WatchPs1)) {
  try {
    $wArgs = @(
      '-NoProfile', '-NoExit', '-File', $WatchPs1,
      '-Root', $Root,
      '-UntilDisarmed',
      '-AlsoLog'
    )
    $wp = Start-Process -FilePath $pwshExe -ArgumentList $wArgs -WorkingDirectory $RepoDir `
      -WindowStyle Minimized -PassThru -ErrorAction Stop
    if ($wp -and $wp.Id) {
      $watchPid = [int]$wp.Id
      Write-Output 'WATCH_DETACH=minimized-console'
    }
  } catch {
    Write-Output ("WATCH_START_WARN {0} — trying detached" -f $_.Exception.Message)
    try {
      $watchCmd = '"{0}" -NoProfile -File {1} -Root {2} -UntilDisarmed -AlsoLog' -f `
        $pwshExe, (Quote-Arg $WatchPs1), (Quote-Arg $Root)
      $wCreated = Start-DetachedProcess -CommandLine $watchCmd -CurrentDirectory $RepoDir
      if ($wCreated.ReturnValue -eq 0 -and $wCreated.ProcessId) {
        $watchPid = [int]$wCreated.ProcessId
        Write-Output ("WATCH_DETACH={0}" -f $wCreated.How)
      }
    } catch {
      Write-Output ("WATCH_DETACH_WARN {0}" -f $_.Exception.Message)
    }
  }
} elseif ($NoWatch) {
  Write-Output 'WATCH_DETACH=skipped (-NoWatch)'
} else {
  Write-Output 'WATCH_DETACH=skipped (autopro-watch.ps1 missing)'
}
Write-Output ("WATCH_PID={0}" -f $watchPid)

Write-Output "SHOWTIME_SESSION=$sessionId"
Write-Output ("ENGINE={0}" -f $resolvedEngine.Engine)
Write-Output ("ENGINE_DISPLAY={0}" -f $resolvedEngine.Display)
Write-Output "RUNNER_PID=$runnerPid"
Write-Output "LAUNCHER_PID=$($proc.Id)"
Write-Output "WORK_DIR=$RepoDir"
Write-Output "SHOWTIME_URL=$boardUrl"
Write-Output "LEDGER_HASH=$ledgerHash"
Write-Output "LEDGER_TITLE=$ledgerTitle"
Write-Output "SKIP_PERMISSIONS=1"
Write-Output ("SLICE_VERIFIER={0}" -f $(if ($NoSliceVerifier) { 'off' } else { 'on' }))
Write-Output ("VERIFIER_MODEL={0}" -f $(if ($VerifierModel) { $VerifierModel } else { 'worker/default' }))
Write-Output "VERIFIER_REPAIR_ATTEMPTS=$VerifierRepairAttempts"
Write-Output ("ALLOW_MODEL_ONLY_FINAL_CHECK={0}" -f $(if ($AllowModelOnlyFinalCheck) { '1' } else { '0' }))
Write-Output "RISK_ACK=AllowDangerousSkipPermissions+IAcceptUnattendedRisk"
Write-Output "STATUS_LOG=$RepoDir\.claude/scratch/SHOWTIME-STATUS.md"
Write-Output 'CHAT_HINT=Chat only: TV card (board URL once on screen) + manual log + needs-you watch (theater/showtime-tv-card.md).'
Write-Output ("NEEDS_YOU={0}" -f (Join-Path $scratch 'AUTOPRO-NEEDS-YOU.md'))
Write-Output ("CHAT_INBOX={0}" -f (Join-Path $scratch 'autopro-chat-inbox.jsonl'))
Write-Output ("Stop: run {0} -Root `"{1}`" or remove .claude/scratch/autopro-on." -f $StopAutoPro, $Root)
