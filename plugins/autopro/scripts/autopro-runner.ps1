<#
  autopro-runner.ps1 -- headless ledger loop + Show Time v2 heartbeats / stats / steers.
#>
param(
  [string]$Root = (Get-Location).Path,
  [string]$RepoDir = (Get-Location).Path,
  [string]$Model = '',
  # Worker engine: auto | claude | codex | gemini | grok | ollama
  [string]$Engine = 'auto',
  [string]$VerifierEngine = '',
  # ollama is text-only by default; require explicit opt-in
  [switch]$AllowOllama,
  [string]$LedgerHash = '',
  [string]$LedgerTitle = '',
  [string]$SessionId = '',
  [switch]$NoShowTime,
  # Only set by launch-showtime after risk ack — never default-on for raw runner invokes
  [switch]$SkipPermissions,
  # Escape hatch: skip independent gate (npm run gate / final-check.ps1 / env cmd)
  [switch]$AllowModelOnlyFinalCheck,
  # Default-on fresh reviewer after every work slice. UI diffs must produce a
  # real Playwright screenshot and zero console/page errors before advancing.
  [switch]$NoSliceVerifier,
  [string]$VerifierModel = '',
  [ValidateRange(0, 3)]
  [int]$VerifierRepairAttempts = 1,
  # Wall-clock kill for hung workers (0 = disabled). Default 90 matches launch.
  [ValidateRange(0, 480)]
  [int]$MaxSliceMinutes = 90
)

$ErrorActionPreference = 'Stop'
$scratch = Join-Path $Root '.claude/scratch'
# Primary ledger (operator source of truth)
$ledgerPrimary = Join-Path $RepoDir '.claude/scratch/ledger.md'
$flag = Join-Path $scratch 'autopro-on'
$log = Join-Path $scratch 'autopro.log'
$sessionStatePath = Join-Path $scratch 'autopro-session.json'
$handoverPath = Join-Path $scratch 'SHOWTIME-HANDOVER.md'
$RegisterPs1 = Join-Path $PSScriptRoot 'theater-register.ps1'
$StatusPs1 = Join-Path $PSScriptRoot 'showtime-status.ps1'
$SliceVerifierPs1 = Join-Path $PSScriptRoot 'showtime-slice-verifier.ps1'
$StateRoot = Join-Path ($env:USERPROFILE ?? $HOME) '.claude/scratch/autopro-theater'
$PortFile = Join-Path $StateRoot 'server.port'
$workerPidFile = Join-Path $scratch 'autopro-worker.pid'
# Live coding-agent pid (0 between slices). Board heartbeats publish this separately
# from runnerPid so Show Time can tell "armed" from "actually coding".
[int]$script:CurrentWorkerPid = 0

# Merge gate lives in one place, shared with test-showtime.ps1
. (Join-Path $PSScriptRoot 'showtime-final-check.ps1')
. (Join-Path $PSScriptRoot 'worker-engines.ps1')
# Cross-platform process enumeration + tree-kill (Windows path is the same CIM/taskkill as before).
. (Join-Path $PSScriptRoot 'proc-crossos.ps1')
# Supervisor v1: kickstart watchdog + needs-you notify + chat inbox bridge
. (Join-Path $PSScriptRoot 'autopro-supervisor.ps1')
if (Test-Path -LiteralPath $SliceVerifierPs1) { . $SliceVerifierPs1 }

# Kickstart: if worker dies in the first N seconds with non-zero exit, retry once.
[int]$script:KickstartGraceSeconds = if ($env:AUTOPRO_KICKSTART_GRACE_SEC) {
  [int]$env:AUTOPRO_KICKSTART_GRACE_SEC
} else { 12 }
[int]$script:KickstartMaxAttempts = if ($env:AUTOPRO_KICKSTART_MAX_ATTEMPTS) {
  [int]$env:AUTOPRO_KICKSTART_MAX_ATTEMPTS
} else { 2 }

# The work happens in the repo itself — there is no isolated tree to prefer.
$WorkDir = $RepoDir
$ledger = $ledgerPrimary

# Resolve worker engine early (fail before burning slices if nothing installed)
try {
  $script:WorkerResolution = Resolve-AutoproEngine -Requested $Engine -AllowOllama:$AllowOllama -Quiet
} catch {
  Write-Output ("FATAL engine resolve: {0}" -f $_.Exception.Message)
  throw
}
$script:EngineId = [string]$script:WorkerResolution.Engine
if ($VerifierEngine -and $VerifierEngine.Trim()) {
  try {
    $script:VerifierResolution = Resolve-AutoproEngine -Requested $VerifierEngine.Trim() -AllowOllama:$AllowOllama -Quiet
  } catch {
    Write-Output ("FATAL verifier engine resolve: {0}" -f $_.Exception.Message)
    throw
  }
} else {
  $script:VerifierResolution = $script:WorkerResolution
}
$script:VerifierEngineId = [string]$script:VerifierResolution.Engine

# Accumulated session stats (model is credit-critical on multi-repo fleets)
$script:Stats = @{
  engine = $script:EngineId
  engineDisplay = [string]$script:WorkerResolution.Display
  model = if ($Model) { $Model } else { '' }
  verifierModel = if ($VerifierModel) { $VerifierModel } else { '' }
  verifierEngine = $script:VerifierEngineId
  modelSource = if ($Model) { 'flag' } else { 'unresolved' }
  measured = $false
  input = 0
  output = 0
  total = 0
  monolithEst = 0
  cacheCreate = 0
  cacheRead = 0
  costUsd = 0.0
  outputHistory = [System.Collections.Generic.List[int]]::new()
  modelSec = 0.0
  filesCreated = 0
  filesTouched = 0
  linesAdded = 0
  linesDeleted = 0
  perSlice = [System.Collections.Generic.List[object]]::new()
}

if (-not $SessionId) {
  $SessionId = 'sess_' + [guid]::NewGuid().ToString('N').Substring(0, 12)
}
$verificationRoot = Join-Path $scratch "autopro-verification/$SessionId"

# Per-session kill switch: each runner owns autopro-on.<sessionId>, so one lane
# finishing (or being stopped) can never disarm its siblings. Legacy bare
# 'autopro-on' is honored for manual runs armed the old way.
$sessionFlag = Join-Path $scratch "autopro-on.$SessionId"
if (Test-Path -LiteralPath $sessionFlag) { $flag = $sessionFlag }

function Get-LedgerIdentity {
  param([string]$Path)
  $title = 'ledger'
  $hash = ''
  if (Test-Path -LiteralPath $Path) {
    $raw = Get-Content -LiteralPath $Path -Raw
    $m = [regex]::Match($raw, '(?m)^#\s+(?:Ledger:\s*)?(.+)$')
    if ($m.Success) { $title = $m.Groups[1].Value.Trim() }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
  }
  [pscustomobject]@{ Title = $title; Hash = $hash }
}

$ledgerIdentity = Get-LedgerIdentity $ledgerPrimary
if (-not $LedgerHash) { $LedgerHash = $ledgerIdentity.Hash }
if (-not $LedgerTitle) { $LedgerTitle = $ledgerIdentity.Title }

function Log($msg) {
  $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  Add-Content -LiteralPath $log -Value $line
  # Console echo ONLY — must NOT go to the success pipeline. Write-Output here
  # leaks the log line into the return value of every function that calls Log
  # before `return`, so a caller like `$hp = Write-Handover ...` receives an
  # array and stringifies as "System.Object[]" (the SC-03 handover corruption).
  # Add-Content above is the durable log; Write-Host is the live echo.
  Write-Host $line
}

function Get-ShowTimeUrl {
  if (-not (Test-Path -LiteralPath $PortFile)) { return $null }
  $p = (Get-Content -LiteralPath $PortFile -Raw).Trim()
  if ($p -notmatch '^\d+$') { return $null }
  return "http://127.0.0.1:$p"
}

function Get-ShowTimeToken {
  $tf = Join-Path ($env:USERPROFILE ?? $HOME) '.claude/scratch/autopro-theater/server.token'
  if (Test-Path -LiteralPath $tf) { return (Get-Content -LiteralPath $tf -Raw).Trim() }
  return ''
}

function Invoke-ShowTimeApi {
  param([string]$Method, [string]$Path, [hashtable]$Body = $null)
  if ($NoShowTime) { return $null }
  $base = Get-ShowTimeUrl
  if (-not $base) { return $null }
  try {
    $params = @{
      Uri             = "$base$Path"
      Method          = $Method
      UseBasicParsing = $true
      TimeoutSec      = 8
      Headers         = @{ 'X-Showtime-Token' = (Get-ShowTimeToken) }
    }
    if ($null -ne $Body) {
      $params.ContentType = 'application/json'
      $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }
    $resp = Invoke-WebRequest @params
    return ($resp.Content | ConvertFrom-Json)
  } catch {
    $msg = $_.Exception.Message
    # Board restart rotates token/port files — re-read once and retry (bulletproof
    # against the common mid-run :8770 bounce without killing the worker).
    if ($msg -match '401|403|404|refused|cannot be made|actively refused') {
      try {
        Start-Sleep -Milliseconds 400
        $base2 = Get-ShowTimeUrl
        $tok2 = Get-ShowTimeToken
        if ($base2 -and $tok2) {
          $params2 = @{
            Uri             = "$base2$Path"
            Method          = $Method
            UseBasicParsing = $true
            TimeoutSec      = 8
            Headers         = @{ 'X-Showtime-Token' = $tok2 }
          }
          if ($null -ne $Body) {
            $params2.ContentType = 'application/json'
            $params2.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
          }
          $resp2 = Invoke-WebRequest @params2
          return ($resp2.Content | ConvertFrom-Json)
        }
      } catch {
        $msg = $_.Exception.Message
      }
    }
    Log ("  showtime> warn: {0}" -f $msg)
    return $null
  }
}

function Build-StatsPayload {
  $total = [int]$script:Stats.total
  $mono = [int]$script:Stats.monolithEst
  $saved = [Math]::Max(0, $mono - $total)
  $savePct = if ($mono -gt 0) { [Math]::Round($saved / $mono, 4) } else { 0 }
  $sec = [Math]::Max(0.001, [double]$script:Stats.modelSec)
  $tps = if ($total -gt 0) { [Math]::Round($total / $sec, 2) } else { 0 }
  $tpm = [Math]::Round($tps * 60, 1)
  $lpt = if ($tpm -gt 0) { [Math]::Round($script:Stats.linesAdded / $tpm, 4) } else { 0 }
  $fpt = if ($tpm -gt 0) { [Math]::Round($script:Stats.filesCreated / $tpm, 4) } else { 0 }
  $modelLabel = if ($script:Stats.model) { [string]$script:Stats.model } else { 'unknown (cli-default)' }
  $verLabel = if ($script:Stats.verifierModel) { [string]$script:Stats.verifierModel } else { $modelLabel }
  $engineLabel = if ($script:Stats.engine) { [string]$script:Stats.engine } else { 'unknown' }
  return @{
    engine         = $engineLabel
    engineDisplay  = [string]$script:Stats.engineDisplay
    model          = $modelLabel
    modelSource    = [string]$script:Stats.modelSource
    verifierModel  = $verLabel
    verifierEngine = [string]$script:Stats.verifierEngine
    measured = [bool]$script:Stats.measured
    tokens   = @{
      input         = [int]$script:Stats.input
      output        = [int]$script:Stats.output
      cacheCreation = [int]$script:Stats.cacheCreate
      cacheRead     = [int]$script:Stats.cacheRead
      costUsd       = [Math]::Round([double]$script:Stats.costUsd, 4)
      total         = $total
      monolithEst   = $mono
      saved         = $saved
      savePct       = $savePct
      # saved/savePct derive from monolithEst (a model, R=0.85) — costUsd,
      # cacheCreation and cacheRead are measured from claude's own usage block.
      savedIsEstimate = $true
    }
    speed    = @{
      tokPerSec    = $tps
      tokPerSecAvg = $tps
      tokPerMin    = $tpm
      lastSliceSec = if ($script:Stats.perSlice.Count) { $script:Stats.perSlice[-1].sec } else { 0 }
    }
    code     = @{
      filesCreated   = [int]$script:Stats.filesCreated
      filesTouched   = [int]$script:Stats.filesTouched
      linesAdded     = [int]$script:Stats.linesAdded
      linesDeleted   = [int]$script:Stats.linesDeleted
      linesPerTokMin = $lpt
      filesPerTokMin = $fpt
    }
    perSlice = @($script:Stats.perSlice)
  }
}

function Invoke-ShowTime {
  param(
    [string]$Action,
    [string]$Status = 'running',
    [string]$StopReason = '',
    [switch]$Progress,
    [switch]$SliceComplete,
    [string]$Sentinel = '',
    [string]$HandoverText = '',
    [string]$SliceId = '',
    [string]$SliceState = '',
    [string]$Outcome = ''
  )
  if ($NoShowTime) { return }
  # Board honesty: runnerPid = conductor (always this process while armed).
  # workerPid = live coding CLI (0 between slices). pid prefers worker when
  # coding so ownership + legs track the real agent; falls back to runner.
  $wPid = [int]$script:CurrentWorkerPid
  $body = @{
    status     = $Status
    ledgerPath = $ledger
    ledgerHash = $LedgerHash
    ledgerTitle = $LedgerTitle
    handoverPath = $handoverPath
    logPath    = $log
    pid        = $(if ($wPid -gt 0) { $wPid } else { $PID })
    runnerPid  = $PID
    workerPid  = $wPid
    stats      = (Build-StatsPayload)
  }
  if ($StopReason) { $body.stopReason = $StopReason }
  if ($Progress) { $body.progress = $true }
  if ($SliceComplete) { $body.sliceComplete = $true }
  if ($Sentinel) { $body.sentinelEntry = @{ text = $Sentinel; level = 'info' } }
  if ($HandoverText) { $body.handoverText = $HandoverText }
  if ($Outcome) { $body.outcome = $Outcome }
  # Name the slice + its state so the board can render "BLOCKED on SC-XX"
  # instead of a stale progress ring on a verify fail (AC2/AC3).
  if ($SliceId) {
    $body.slice = @{
      id    = $SliceId
      state = $(if ($SliceState) { $SliceState } else { 'in-progress' })
    }
  }

  if ($Action -eq 'register') {
    $body.sessionId = $SessionId
    $body.repoId = [IO.Path]::GetFileName($RepoDir.TrimEnd('\', '/'))
    $body.repoPath = $WorkDir
    $body.primaryRepo = $RepoDir
    try {
      Push-Location $WorkDir
      $body.branch = ("$(git rev-parse --abbrev-ref HEAD 2>$null)").Trim()
    } catch { $body.branch = '' }
    finally { Pop-Location }
    $null = Invoke-ShowTimeApi -Method POST -Path '/api/sessions' -Body $body
    return
  }
  if ($Action -eq 'complete') {
    $body.status = 'complete'
    $null = Invoke-ShowTimeApi -Method POST -Path "/api/sessions/$SessionId/heartbeat" -Body $body
    return
  }
  $null = Invoke-ShowTimeApi -Method POST -Path "/api/sessions/$SessionId/heartbeat" -Body $body
}

function Get-Counts {
  if (-not (Test-Path -LiteralPath $ledger)) { return $null }
  $t = Get-Content -LiteralPath $ledger -Raw
  $id = '(?:SC-\d+|SD-[\w-]+|H\d+|P\d+[-\w]*)'
  $pending = ([regex]::Matches($t, "(?m)^##\s+$id[^\n]*\[pending\]")).Count
  $inprog = ([regex]::Matches($t, "(?m)^##\s+$id[^\n]*\[in-progress\]")).Count
  $blocked = ([regex]::Matches($t, "(?m)^##\s+$id[^\n]*\[blocked\]")).Count
  $done = ([regex]::Matches($t, "(?m)^##\s+$id[^\n]*\[done\]")).Count
  # No loose fallback: counting bare [pending] anywhere in the file counts
  # prose (documented failure 2026-07). Unmatched ledgers stop the runner
  # with 'empty/template ledger' instead of chasing phantom slices.
  [pscustomobject]@{
    Approved   = [bool]([regex]::IsMatch($t, '(?im)^Approved:\s*yes'))
    Pending    = $pending
    InProgress = $inprog
    Blocked    = $blocked
    Done       = $done
  }
}

function Get-NextSliceInfo {
  if (-not (Test-Path -LiteralPath $ledger)) {
    return [pscustomobject]@{ Id = 'slice'; Title = 'unknown slice' }
  }
  $raw = Get-Content -LiteralPath $ledger -Raw
  $id = '(?:SC-\d+|SD-[\w-]+|H\d+|P\d+[-\w]*)'
  $m = [regex]::Match($raw, "(?m)^##\s+($id)\s+(?:[—–-]\s*)?(.+?)\s+\[(pending|in-progress)\]\s*$")
  if (-not $m.Success) {
    return [pscustomobject]@{ Id = 'slice'; Title = 'next ledger slice' }
  }
  return [pscustomobject]@{
    Id = $m.Groups[1].Value.Trim()
    Title = $m.Groups[2].Value.Trim()
  }
}

function Get-SteersText {
  # Must return a pure [string]. Log() Write-Outputs to the pipeline — if we call
  # Log without capturing, the caller gets Object[] and Invoke-ClaudeProcess -Prompt
  # throws "Cannot convert value to type System.String" (killed SC-65 arm 2026-07-12).
  $r = Invoke-ShowTimeApi -Method POST -Path "/api/sessions/$SessionId/consume-steers" -Body @{}
  if (-not $r -or -not $r.steers) { return [string]'' }
  $parts = [System.Collections.Generic.List[string]]::new()
  foreach ($st in @($r.steers)) {
    $kind = if ($st.kind) { [string]$st.kind } else { 'steer' }
    $label = switch ($kind.ToLowerInvariant()) {
      'nudge' { 'OPERATOR NUDGE' }
      'answer' { 'OPERATOR ANSWER' }
      'message' { 'OPERATOR MESSAGE' }
      default { 'OPERATOR STEER' }
    }
    $target = if ($st.target) { [string]$st.target } else { 'next' }
    $text = if ($null -eq $st.text) { '' } else { [string]$st.text }
    [void]$parts.Add(("{0} ({1}): {2}" -f $label, $target, $text))
  }
  if ($parts.Count -eq 0) { return [string]'' }
  $null = Log ("steers: consumed {0} message(s) for next claude -p" -f $parts.Count)
  # Clear one-shot nudge flag if present
  try {
    $nudgeFlag = Join-Path ($env:USERPROFILE ?? $HOME) ".claude/scratch/autopro-theater/steer/${SessionId}.nudge"
    if (Test-Path -LiteralPath $nudgeFlag) {
      Remove-Item -LiteralPath $nudgeFlag -Force -ErrorAction SilentlyContinue
    }
  } catch {}
  return [string](($parts -join "`n") + "`n`n")
}

# Show Time runs ZERO git. The worker session owns its own commits via the `work`
# skill, in the repo, on the operator's branch. There is no Invoke-ScopedCommit
# and no Invoke-FinishMergeAndPrune: that authority is what stranded work in
# orphaned worktrees, so it is DELETED, not stubbed. A no-op stub would just be a
# socket to plug it back into.
function Invoke-StatusLog {
  param(
    [ValidateSet('refresh', 'event', 'init')]
    [string]$Action = 'refresh',
    [string]$Event = '',
    [ValidateSet('done', 'block', 'server', 'info', 'finish')]
    [string]$Level = 'info',
    [string]$Commit = ''
  )
  if (-not (Test-Path -LiteralPath $StatusPs1)) { return }
  try {
    $statusArgs = @(
      '-NoProfile', '-File', $StatusPs1,
      '-RepoDir', $RepoDir,
      '-Action', $Action,
      '-SessionId', $SessionId,
      '-LedgerPath', $ledger
    )
    if ($Event) { $statusArgs += @('-Event', $Event, '-Level', $Level) }
    if ($Commit) { $statusArgs += @('-Commit', $Commit) }
    & pwsh @statusArgs 2>&1 | ForEach-Object { Log ("  status> {0}" -f $_) }
  } catch {
    Log ("  status> warn: {0}" -f $_.Exception.Message)
  }
}

function Get-GitDelta([string]$startSha) {
  $result = @{ filesCreated = 0; filesTouched = 0; linesAdded = 0; linesDeleted = 0 }
  if (-not $startSha) { return $result }
  try {
    Push-Location -LiteralPath $WorkDir
    $num = & git diff --numstat $startSha 2>$null
    $name = & git diff --name-status $startSha 2>$null
    if ($num) {
      foreach ($line in $num) {
        if ($line -match '^\s*(\d+)\s+(\d+)\s+') {
          $result.linesAdded += [int]$Matches[1]
          $result.linesDeleted += [int]$Matches[2]
          $result.filesTouched++
        } elseif ($line -match '^\s*-\s+-\s+') {
          $result.filesTouched++
        }
      }
    }
    if ($name) {
      foreach ($line in $name) {
        if ($line -match '^A\s+') { $result.filesCreated++ }
      }
    }
  } catch {}
  finally { Pop-Location }
  return $result
}

function Resolve-WorkerModelLabel {
  # Prefer explicit -Model, then AUTOPRO_MODEL / engine-specific env, then pending.
  if ($Model -and $Model.Trim()) {
    return [pscustomobject]@{ Model = $Model.Trim(); Source = 'flag' }
  }
  if ($env:AUTOPRO_MODEL -and $env:AUTOPRO_MODEL.Trim()) {
    return [pscustomobject]@{ Model = $env:AUTOPRO_MODEL.Trim(); Source = 'env:AUTOPRO_MODEL' }
  }
  $envNames = @('ANTHROPIC_MODEL', 'CLAUDE_MODEL', 'CLAUDE_CODE_MODEL', 'OPENAI_MODEL', 'CODEX_MODEL', 'GEMINI_MODEL', 'GOOGLE_MODEL', 'GROK_MODEL', 'XAI_MODEL', 'OLLAMA_MODEL')
  foreach ($envName in $envNames) {
    $v = [string][Environment]::GetEnvironmentVariable($envName)
    if ($v -and $v.Trim()) {
      return [pscustomobject]@{ Model = $v.Trim(); Source = "env:$envName" }
    }
  }
  if ($script:WorkerResolution -and $script:WorkerResolution.DefaultModel) {
    return [pscustomobject]@{ Model = [string]$script:WorkerResolution.DefaultModel; Source = 'engine-default' }
  }
  return [pscustomobject]@{ Model = ''; Source = 'pending-worker-result' }
}

function Parse-UsageFromText([string]$text) {
  # JSON-first: `claude -p --output-format json` puts the truth in the result
  # object's usage block. The old first-regex-match approach missed cache
  # tokens entirely (~2/3 of real input) and ignored total_cost_usd.
  $in = 0; $out = 0; $cacheCreate = 0; $cacheRead = 0; $cost = 0.0; $measured = $false
  $modelId = ''
  foreach ($line in ($text -split "`r?`n")) {
    $l = $line.Trim()
    # Runner log lines prefix claude stdout with "  | " — strip before probing.
    if ($l -match '^\|\s*(.+)$') { $l = $Matches[1].Trim() }
    if (-not ($l.StartsWith('{') -and $l.EndsWith('}'))) { continue }
    $obj = $null
    try { $obj = $l | ConvertFrom-Json -ErrorAction Stop } catch { continue }
    foreach ($node in @($obj)) {
      # Capture model id from any JSON event that carries it
      if (-not $modelId) {
        if ($node.model) { $modelId = [string]$node.model }
        elseif ($node.message -and $node.message.model) { $modelId = [string]$node.message.model }
      }
      if ($node.type -ne 'result' -or $null -eq $node.usage) { continue }
      $u = $node.usage
      $in = [int]($u.input_tokens ?? 0)
      $out = [int]($u.output_tokens ?? 0)
      $cacheCreate = [int]($u.cache_creation_input_tokens ?? 0)
      $cacheRead = [int]($u.cache_read_input_tokens ?? 0)
      if ($null -ne $node.total_cost_usd) { $cost = [double]$node.total_cost_usd }
      if ($node.model) { $modelId = [string]$node.model }
      $measured = $true
    }
  }
  if (-not $measured) {
    if ($text -match '"input_tokens"\s*:\s*(\d+)') { $in = [int]$Matches[1]; $measured = $true }
    if ($text -match '"output_tokens"\s*:\s*(\d+)') { $out = [int]$Matches[1]; $measured = $true }
    if ($text -match '"cache_creation_input_tokens"\s*:\s*(\d+)') { $cacheCreate = [int]$Matches[1] }
    if ($text -match '"cache_read_input_tokens"\s*:\s*(\d+)') { $cacheRead = [int]$Matches[1] }
    if ($text -match '"total_cost_usd"\s*:\s*([0-9.]+)') { $cost = [double]$Matches[1] }
  }
  if (-not $modelId -and $text -match '"model"\s*:\s*"([^"]+)"') { $modelId = $Matches[1] }
  if (-not $measured) {
    $in = [Math]::Max(1, [int]($text.Length / 4))
    $out = [Math]::Max(1, [int]($text.Length / 8))
  }
  return @{
    input = $in; output = $out; measured = $measured
    cacheCreate = $cacheCreate; cacheRead = $cacheRead; costUsd = $cost
    model = $modelId
  }
}

function Get-RecentLogLines([int]$Count = 80) {
  if (-not (Test-Path -LiteralPath $log)) { return @() }
  return @(Get-Content -LiteralPath $log -Tail $Count -ErrorAction SilentlyContinue)
}

function Get-TrackedWorktreeStatus {
  try {
    Push-Location -LiteralPath $WorkDir
    return (@(& git status --porcelain --untracked-files=no 2>$null) -join "`n")
  } catch { return '' }
  finally { Pop-Location }
}

# Read-only. The handover names the branch the worker committed to, since Show
# Time no longer moves that work anywhere.
function Get-CurrentBranch {
  try {
    Push-Location -LiteralPath $RepoDir
    $b = (& git rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
    if (-not $b -or $b -eq 'HEAD') {
      $s = (& git rev-parse --short HEAD 2>$null | Out-String).Trim()
      return $(if ($s) { "detached@$s" } else { 'unknown' })
    }
    return $b
  } catch { return 'unknown' }
  finally { Pop-Location }
}

function Get-ChangedFilesSince([string]$StartSha) {
  if (-not $StartSha) { return @() }
  try {
    Push-Location -LiteralPath $WorkDir
    return @(& git diff --name-only "$StartSha..HEAD" 2>$null | Where-Object { $_ })
  } catch { return @() }
  finally { Pop-Location }
}

function Invoke-SupervisorNeedsYou {
  param(
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Summary,
    [string]$Detail = '',
    [string]$HandoverPath = '',
    [hashtable]$Extra = $null
  )
  try {
    $alert = Send-AutoproSupervisorAlert `
      -ScratchDir $scratch `
      -Kind $Kind `
      -Summary $Summary `
      -Detail $Detail `
      -SessionId $SessionId `
      -RepoDir $RepoDir `
      -HandoverPath $HandoverPath `
      -LogPath $log `
      -Extra $Extra
    Log ("SUPERVISOR_ALERT kind={0} needsYou={1} toast={2}" -f $Kind, $alert.NeedsYouMd, $alert.Toast)
    try {
      Invoke-ShowTime -Action heartbeat -Status blocked -StopReason $Kind `
        -Sentinel ("NEEDS YOU · {0} · see AUTOPRO-NEEDS-YOU.md" -f $Kind)
    } catch {}
    return $alert
  } catch {
    Log ("SUPERVISOR_ALERT_FAILED: {0}" -f $_.Exception.Message)
    return $null
  }
}

function Invoke-WorkerProcess {
  <#
    Spawn the resolved agent CLI for one prompt (slice / verify / final check).
    Engine-agnostic: uses worker-engines.ps1 resolution + argv builders.
    Supervisor v1: if the process dies in the kickstart grace window with a
    non-zero exit, retry once (KICKSTART_RETRY) then alert (KICKSTART_FAILED).
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Prompt,
    [string]$ModelName = '',
    [string]$LogPrefix = '  | ',
    [string]$HeartbeatLabel = 'slice live',
    $Resolution = $null
  )

  if (-not $SkipPermissions) {
    throw 'REFUSE: detached worker process requires -SkipPermissions (no TTY for approval prompts)'
  }
  $res = if ($null -ne $Resolution) { $Resolution } else { $script:WorkerResolution }
  if (-not $res -or -not $res.Available) {
    throw "Worker engine not available: $($res.Engine) — $($res.Hint)"
  }
  if ($res.FileName -match '\.(ps1|cmd)$') {
    throw "REFUSE: resolved worker path is a shim ($($res.FileName)) — use real .exe or node cli.js"
  }

  $extraArgs = Build-WorkerArgumentList -Resolution $res -Prompt $Prompt -ModelName $ModelName `
    -WorkDir $WorkDir -SkipPermissions:$SkipPermissions

  $maxAttempts = [Math]::Max(1, $script:KickstartMaxAttempts)
  $graceSec = [Math]::Max(3, $script:KickstartGraceSeconds)
  $lastText = ''
  $lastExit = -1
  $lastSec = 0.0
  $lastUsage = $null
  $lastTimedOut = $false
  $lastLineCount = 0

  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $res.FileName
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    foreach ($a in @($res.PrefixArgs)) {
      if ($null -ne $a -and [string]$a -ne '') { [void]$psi.ArgumentList.Add([string]$a) }
    }
    foreach ($a in $extraArgs) {
      [void]$psi.ArgumentList.Add([string]$a)
    }

    Log ("  engine={0} exe={1} risk={2} kickstartAttempt={3}/{4}" -f $res.Engine, $res.Display, (Get-EngineRiskLabel -Engine $res.Engine), $attempt, $maxAttempts)
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
      $started = $false
      try { $started = $proc.Start() } catch {
        Log ("  KICKSTART_START_THROW: {0}" -f $_.Exception.Message)
        $started = $false
      }
      if (-not $started) {
        if (Should-KickstartRetry -EarlyExit $true -ExitCode 1 -Attempt $attempt -MaxAttempts $maxAttempts) {
          Log '  KICKSTART_RETRY: process failed to start'
          try {
            Invoke-ShowTime -Action heartbeat -Status stalled -StopReason 'Kickstart retry' `
              -Sentinel ("KICKSTART_RETRY · {0} · start-failed" -f $res.Engine)
          } catch {}
          Start-Sleep -Milliseconds 800
          continue
        }
        throw ("{0} process failed to start" -f $res.Engine)
      }
      try { $proc.StandardInput.Close() } catch {}
      try {
        $script:CurrentWorkerPid = [int]$proc.Id
        [string]$proc.Id | Set-Content -LiteralPath $workerPidFile -Encoding ascii -Force
      } catch {
        $script:CurrentWorkerPid = 0
      }
      try {
        Invoke-ShowTime -Action heartbeat -Status running -Progress `
          -Sentinel ("Worker pid {0} · {1} · attempt {2}" -f $proc.Id, $res.Engine, $attempt)
      } catch {}

      $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
      $stderrTask = $proc.StandardError.ReadToEndAsync()

      # --- Kickstart grace: detect instant death ---
      $kick = Test-WorkerKickstartAlive -Process $proc -GraceSeconds $graceSec
      if ($kick.EarlyExit) {
        $stdout = ''; $stderr = ''
        try { $stdout = $stdoutTask.GetAwaiter().GetResult() } catch {}
        try { $stderr = $stderrTask.GetAwaiter().GetResult() } catch {}
        $parts = @()
        if ($stdout) { $parts += $stdout.TrimEnd("`r", "`n") }
        if ($stderr) { $parts += $stderr.TrimEnd("`r", "`n") }
        $text = $parts -join "`n"
        $code = if ($null -ne $kick.ExitCode) { [int]$kick.ExitCode } elseif ($proc.HasExited) { $proc.ExitCode } else { -1 }
        Log ("  KICKSTART_EARLY_EXIT code={0} sec={1} attempt={2}" -f $code, $kick.Seconds, $attempt)
        if (Should-KickstartRetry -EarlyExit $true -ExitCode $code -Attempt $attempt -MaxAttempts $maxAttempts) {
          Log ("  KICKSTART_RETRY: early death code={0} within {1}s — re-spawning once" -f $code, $graceSec)
          try {
            Invoke-ShowTime -Action heartbeat -Status stalled -StopReason 'Kickstart retry' `
              -Sentinel ("KICKSTART_RETRY · {0} · exit {1}" -f $res.Engine, $code)
          } catch {}
          Start-Sleep -Milliseconds 800
          continue
        }
        $usage = Parse-WorkerUsageFromText -Text $text -Engine $res.Engine
        $lineCount = @($text -split "`r?`n" | Where-Object { $_ }).Count
        # Exit 0 inside grace = intentional short success (finalizer/tiny work) — not a kickstart fail.
        if ([int]$code -eq 0) {
          Log ("  kickstart: early exit 0 in {0}s — treating as short success" -f $kick.Seconds)
          return [pscustomobject]@{
            Text      = $text
            ExitCode  = 0
            Seconds   = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
            LineCount = $lineCount
            Engine    = $res.Engine
            Usage     = $usage
            TimedOut  = $false
            KickstartFailed = $false
          }
        }
        # Final early failure
        $failMsg = ("Worker died within kickstart grace ({0}s) exit={1} engine={2}" -f $graceSec, $code, $res.Engine)
        Log ("  KICKSTART_FAILED: {0}" -f $failMsg)
        $null = Invoke-SupervisorNeedsYou -Kind 'kickstart-failed' -Summary $failMsg -Detail $text `
          -Extra @{ engine = $res.Engine; exitCode = $code; graceSeconds = $graceSec }
        return [pscustomobject]@{
          Text      = $text
          ExitCode  = $code
          Seconds   = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
          LineCount = $lineCount
          Engine    = $res.Engine
          Usage     = $usage
          TimedOut  = $false
          KickstartFailed = $true
        }
      }

      # Still alive past grace — run to completion / timeout
      $lastHb = [DateTime]::UtcNow
      $timedOut = $false
      $maxSec = if ($MaxSliceMinutes -gt 0) { [double]($MaxSliceMinutes * 60) } else { 0.0 }
      while (-not $proc.WaitForExit(1000)) {
        $now = [DateTime]::UtcNow
        if ($maxSec -gt 0 -and $sw.Elapsed.TotalSeconds -ge $maxSec) {
          $timedOut = $true
          Log ("  worker TIMEOUT after {0}m — killing pid {1} ({2})" -f $MaxSliceMinutes, $proc.Id, $res.Engine)
          try {
            if (Stop-ProcessTree -Id $proc.Id) { Log ("  killed tree pid {0}" -f $proc.Id) }
            else { throw 'Stop-ProcessTree returned false' }
          } catch {
            try { $proc.Kill($true) } catch { try { $proc.Kill() } catch {} }
          }
          try {
            Invoke-ShowTime -Action heartbeat -Status stalled -StopReason ("Worker timeout {0}m" -f $MaxSliceMinutes) `
              -Sentinel ("TIMEOUT · {0} · {1}m" -f $res.Engine, $MaxSliceMinutes)
          } catch {}
          $null = Invoke-SupervisorNeedsYou -Kind 'worker-timeout' `
            -Summary ("Worker timed out after {0}m ({1})" -f $MaxSliceMinutes, $res.Engine) `
            -Detail ("pid={0} engine={1}" -f $proc.Id, $res.Engine)
          break
        }
        if (($now - $lastHb).TotalSeconds -ge 45) {
          $lastHb = $now
          try {
            Invoke-ShowTime -Action heartbeat -Status running -Progress `
              -Sentinel ("{0} · {1} · pid {2} · {3:n0}s" -f $res.Engine, $HeartbeatLabel, $proc.Id, $sw.Elapsed.TotalSeconds)
          } catch {}
        }
      }
      if (-not $proc.HasExited) {
        try { $proc.WaitForExit(15000) } catch {}
      }
      $stdout = ''
      $stderr = ''
      try { $stdout = $stdoutTask.GetAwaiter().GetResult() } catch {}
      try { $stderr = $stderrTask.GetAwaiter().GetResult() } catch {}
      $parts = @()
      if ($stdout) { $parts += $stdout.TrimEnd("`r", "`n") }
      if ($stderr) { $parts += $stderr.TrimEnd("`r", "`n") }
      if ($timedOut) { $parts += ("AUTOPRO_WORKER_TIMEOUT=1 maxSliceMinutes={0}" -f $MaxSliceMinutes) }
      $text = $parts -join "`n"
      $lines = @($text -split "`r?`n" | Where-Object { $_ -ne '' })
      for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        if ($i -lt 20 -or (($i + 1) % 50) -eq 0 -or $line.Length -lt 400) {
          Log ("{0}{1}" -f $LogPrefix, $(if ($line.Length -gt 500) { $line.Substring(0, 500) + '…' } else { $line }))
        }
      }
      $usage = Parse-WorkerUsageFromText -Text $text -Engine $res.Engine
      $exitCode = if ($timedOut) { 124 } elseif ($proc.HasExited) { $proc.ExitCode } else { 124 }
      return [pscustomobject]@{
        Text      = $text
        ExitCode  = $exitCode
        Seconds   = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        LineCount = $lines.Count
        Engine    = $res.Engine
        Usage     = $usage
        TimedOut  = $timedOut
        KickstartFailed = $false
      }
    } finally {
      $sw.Stop()
      $script:CurrentWorkerPid = 0
      try { Remove-Item -LiteralPath $workerPidFile -Force -ErrorAction SilentlyContinue } catch {}
      try { $proc.Dispose() } catch {}
    }
  }

  # Should not reach: loop always returns or throws
  throw ("Worker kickstart exhausted {0} attempts" -f $maxAttempts)
}

# Back-compat alias (older call sites / docs)
function Invoke-ClaudeProcess {
  param(
    [Parameter(Mandatory = $true)][string]$Prompt,
    [string]$ModelName = '',
    [string]$LogPrefix = '  | ',
    [string]$HeartbeatLabel = 'slice live'
  )
  Invoke-WorkerProcess -Prompt $Prompt -ModelName $ModelName -LogPrefix $LogPrefix -HeartbeatLabel $HeartbeatLabel
}

function Invoke-SliceVerification {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$StartSha,
    [Parameter(Mandatory = $true)][string]$SliceId,
    [Parameter(Mandatory = $true)][string]$SliceTitle,
    [int]$Attempt = 1
  )

  if ($NoSliceVerifier) {
    return [pscustomobject]@{ Green = $true; Skipped = $true; UiChanged = $false; Text = 'slice verifier disabled'; ExitCode = 0; WorktreeChanged = $false }
  }
  if (-not $StartSha) {
    return [pscustomobject]@{ Green = $false; Skipped = $false; UiChanged = $false; Text = 'missing slice start SHA'; ExitCode = 78; WorktreeChanged = $false }
  }
  if (-not (Test-Path -LiteralPath $SliceVerifierPs1) -or -not (Get-Command Test-SliceVerificationGreen -ErrorAction SilentlyContinue)) {
    return [pscustomobject]@{ Green = $false; Skipped = $false; UiChanged = $false; Text = 'slice verifier policy helper missing'; ExitCode = 78; WorktreeChanged = $false }
  }

  $changedFiles = @(Get-ChangedFilesSince $StartSha)
  $uiChanged = Test-AutoproUiChange $changedFiles
  New-Item -ItemType Directory -Force -Path $verificationRoot | Out-Null
  $safeId = ($SliceId -replace '[^a-zA-Z0-9._-]', '_')
  $evidencePath = if ($uiChanged) { Join-Path $verificationRoot ("{0}-attempt-{1}.png" -f $safeId, $Attempt) } else { '' }
  if ($evidencePath) { Remove-Item -LiteralPath $evidencePath -Force -ErrorAction SilentlyContinue }
  $changedList = if ($changedFiles.Count) { (($changedFiles | Select-Object -First 120) -join "`n") } else { '(no committed files detected)' }
  $uiText = if ($uiChanged) { 'true' } else { 'false' }
  $evidenceText = if ($evidencePath) { $evidencePath } else { '(not required for a non-UI slice)' }

  $prompt = @"
You are AutoPro's independent post-slice verifier. You are a fresh session that
comes AFTER the implementation worker. VERIFY ONLY: do not edit, format, commit,
or rewrite any tracked file. Do not start another ledger slice.

Slice: $SliceId — $SliceTitle
Diff: $StartSha..HEAD
UI_CHANGED=$uiText

Changed files:
$changedList

Required work:
1. Read the committed diff and the slice acceptance notes in .claude/scratch/ledger.md.
2. Run focused deterministic tests, syntax/type checks, and security checks appropriate to the diff.
3. If UI_CHANGED=true, you MUST use the repo's installed Playwright tooling in headless/background mode,
   start or reuse the app/preview as needed, exercise the changed interaction, capture console errors and
   page errors, and write a real screenshot to this exact path:
   $evidenceText
   Clean up only processes you started. Do not use the visible IDE chat UI.
4. If UI_CHANGED=false, Playwright may be skipped only as skipped-non-ui.
5. Be fail-closed. Missing dependencies, an unavailable preview, test failures, browser errors, or missing
   screenshot evidence are RED, not assumptions.

Finish with these exact machine-readable lines (plain text, one each):
SLICE_VERIFY_STATUS=green|red
PLAYWRIGHT_STATUS=green|red|skipped-non-ui
CONSOLE_ERRORS=<integer>
PAGE_ERRORS=<integer>
PLAYWRIGHT_COMMAND=<actual command or skipped-non-ui>
PLAYWRIGHT_EVIDENCE=$evidenceText

Green is allowed only when every relevant check passed. Do not claim green from code inspection alone for UI work.
"@

  Log ("verify: spawn fresh reviewer for {0} attempt={1} ui={2} files={3}" -f $SliceId, $Attempt, $uiChanged, $changedFiles.Count)
  Invoke-ShowTime -Action heartbeat -Status running -Progress -Sentinel ("Playwright verifier · {0} · attempt {1}" -f $SliceId, $Attempt)
  $beforeStatus = Get-TrackedWorktreeStatus
  $exitCode = 1
  $verifyText = ''
  $verifySeconds = 0
  try {
    $reviewModel = if ($VerifierModel) { $VerifierModel } else { $Model }
    $processResult = Invoke-WorkerProcess -Prompt $prompt -ModelName $reviewModel -LogPrefix '  verify| ' `
      -HeartbeatLabel ("verifier live · {0}" -f $SliceId) -Resolution $script:VerifierResolution
    $verifyText = $processResult.Text
    $verifySeconds = $processResult.Seconds
    $exitCode = $processResult.ExitCode
  } catch {
    $verifyText = "VERIFIER_EXCEPTION=$($_.Exception.Message)"
    Log ("  verify> exception: {0}" -f $_.Exception.Message)
    $exitCode = 1
  }
  $afterStatus = Get-TrackedWorktreeStatus
  $result = [pscustomobject]@{
    Text = $verifyText
    ExitCode = $exitCode
    WorktreeChanged = ($beforeStatus -ne $afterStatus)
    UiChanged = $uiChanged
    EvidencePath = $evidencePath
    ChangedFiles = $changedFiles
    Seconds = $verifySeconds
  }
  $green = Test-SliceVerificationGreen -Result $result -UiChanged:$uiChanged -EvidencePath $evidencePath
  $result | Add-Member -NotePropertyName Green -NotePropertyValue $green
  $result | Add-Member -NotePropertyName Skipped -NotePropertyValue $false
  Log ("verify: result slice={0} green={1} exit={2} worktreeChanged={3} evidence={4}" -f $SliceId, $green, $exitCode, $result.WorktreeChanged, $(if ($evidencePath) { $evidencePath } else { 'n/a' }))
  Invoke-ShowTime -Action heartbeat -Status $(if ($green) { 'running' } else { 'paused' }) -Progress:$green -Sentinel ("Verifier {0} · {1} · attempt {2}" -f $(if ($green) { 'GREEN' } else { 'RED' }), $SliceId, $Attempt)
  return $result
}

function Write-SessionState([string]$State, [string]$Outcome = '', [string]$Handover = '') {
  try {
    # Always stamp this process PID so launch/status can reconcile dead "running" sessions
    # (silent-start / killed-runner class from 00:44 and 02:38 logs).
    $prior = $null
    if (Test-Path -LiteralPath $sessionStatePath) {
      try { $prior = Get-Content -LiteralPath $sessionStatePath -Raw | ConvertFrom-Json } catch { $prior = $null }
    }
    $obj = [ordered]@{
      sessionId    = $SessionId
      state        = $State
      outcome      = $Outcome
      ledgerHash   = $LedgerHash
      ledgerTitle  = $LedgerTitle
      repoDir      = $RepoDir
      runnerPid    = $PID
      handoverPath = $Handover
      updatedAt    = (Get-Date).ToString('o')
    }
    if ($prior) {
      if (-not $obj.ledgerHash -and $prior.ledgerHash) { $obj.ledgerHash = [string]$prior.ledgerHash }
      if (-not $obj.ledgerTitle -and $prior.ledgerTitle) { $obj.ledgerTitle = [string]$prior.ledgerTitle }
    }
    $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sessionStatePath -Encoding utf8
  } catch {}
}

function Write-Handover {
  param(
    [Parameter(Mandatory = $true)][string]$Outcome,
    [object]$FinalCheck = $null,
    [string]$Notes = ''
  )
  $counts = Get-Counts
  $stats = Build-StatsPayload
  $finalExit = if ($FinalCheck) { [int]$FinalCheck.ExitCode } else { -1 }
  $finalGreen = if ($FinalCheck) { Test-FinalCheckGreen $FinalCheck } else { $false }
  $recent = Get-RecentLogLines 80
  $finalTail = @()
  if ($FinalCheck -and $FinalCheck.Text) {
    $finalTail = @(([string]$FinalCheck.Text -split "`r?`n") | Select-Object -Last 80)
  }

  $ledgerText = ''
  try {
    if (Test-Path -LiteralPath $ledger) {
      $ledgerText = Get-Content -LiteralPath $ledger -Raw -ErrorAction SilentlyContinue
    }
  } catch { $ledgerText = '' }

  $inv = $null
  try {
    if ($ledgerText) { $inv = Get-LedgerSliceInventory -LedgerText $ledgerText }
  } catch { $inv = $null }

  $stillTodo = [System.Collections.Generic.List[string]]::new()
  if ($inv) {
    foreach ($s in @($inv.Pending)) {
      [void]$stillTodo.Add(("Ledger slice still [pending]: {0} — {1}" -f $s.Id, $s.Title))
    }
    foreach ($s in @($inv.InProgress)) {
      [void]$stillTodo.Add(("Ledger slice still [in-progress]: {0} — {1}" -f $s.Id, $s.Title))
    }
    foreach ($s in @($inv.Blocked)) {
      [void]$stillTodo.Add(("Ledger slice [blocked]: {0} — {1}" -f $s.Id, $s.Title))
    }
    foreach ($line in @($inv.OutOfScope)) {
      $t = $line -replace '^\s*[-*]\s*', '' -replace '^\s*\d+\.\s*', ''
      if ($t) { [void]$stillTodo.Add(("Out of scope (next epic): {0}" -f $t)) }
    }
    foreach ($line in @($inv.AfterDone)) {
      $t = $line -replace '^\s*[-*]\s*', '' -replace '^\s*\d+\.\s*', ''
      if ($t) { [void]$stillTodo.Add(("After 100% checklist: {0}" -f $t)) }
    }
  }
  if ($Outcome -ne 'complete') {
    [void]$stillTodo.Add(("AutoPro outcome was ``{0}`` — not a clean complete; fix before treating epic as shipped." -f $Outcome))
  }
  if (-not $finalGreen -and $FinalCheck) {
    [void]$stillTodo.Add('Final check was not green — re-run check skill / independent gate.')
  }
  try {
    $hints = Get-WiringStillTodoHints -LedgerText $ledgerText -Notes $Notes -ExtraLines @($finalTail)
    foreach ($h in @($hints)) { [void]$stillTodo.Add($h) }
  } catch {}
  # Always remind ops reality
  [void]$stillTodo.Add('Confirm secrets/env on the target host (never assume AutoPro wrote production secrets).')
  [void]$stillTodo.Add('Confirm deploy/CI and any Supabase · edge functions · CORS · Engine pin on the environment that will run this tip.')

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('# SHOWTIME HANDOVER')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('| | |')
  [void]$sb.AppendLine('|--|--|')
  [void]$sb.AppendLine("| Session | ``$SessionId`` |")
  [void]$sb.AppendLine("| Outcome | ``$Outcome`` |")
  [void]$sb.AppendLine("| Ledger | $LedgerTitle |")
  [void]$sb.AppendLine("| Ledger hash | ``$LedgerHash`` |")
  [void]$sb.AppendLine("| Repo | ``$RepoDir`` |")
  [void]$sb.AppendLine("| Branch | ``$(Get-CurrentBranch)`` |")
  [void]$sb.AppendLine("| Engine | ``$($script:EngineId)`` |")
  [void]$sb.AppendLine("| Final check exit | ``$finalExit`` |")
  [void]$sb.AppendLine("| Final check green | ``$finalGreen`` |")
  [void]$sb.AppendLine("| Git | ``Show Time runs zero git — the worker committed to the branch above`` |")
  [void]$sb.AppendLine("| Generated | ``$((Get-Date).ToString('o'))`` |")
  if ($counts) {
    [void]$sb.AppendLine("| Counts | done=$($counts.Done), pending=$($counts.Pending), in-progress=$($counts.InProgress), blocked=$($counts.Blocked) |")
  }
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('## Orchestrator report')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('This handover is the **runner/orchestrator report** for the arming human and the next chat.')
  [void]$sb.AppendLine('ORCH on the board is desk-only; this file is the durable handoff.')
  [void]$sb.AppendLine('')
  if ($Outcome -eq 'complete' -and $finalGreen) {
    [void]$sb.AppendLine('- **Ledger status:** AutoPro marks the epic **complete** (final check green + independent gate if configured).')
  } elseif ($Outcome -eq 'complete') {
    [void]$sb.AppendLine('- **Ledger status:** AutoPro claimed complete but final check marker was not green — treat as **incomplete**.')
  } else {
    [void]$sb.AppendLine(("- **Ledger status:** AutoPro **stopped early** (`{0}`). Do not ship until resolved." -f $Outcome))
  }
  [void]$sb.AppendLine(("- **Token stats:** input={0}, output={1}, total={2}, saved={3}" -f $stats.tokens.input, $stats.tokens.output, $stats.tokens.total, $stats.tokens.saved))
  if ($Notes) { [void]$sb.AppendLine(("- **Notes:** {0}" -f $Notes)) }
  [void]$sb.AppendLine('')

  [void]$sb.AppendLine('## Slice inventory')
  [void]$sb.AppendLine('')
  if ($inv -and $inv.Slices.Count) {
    [void]$sb.AppendLine('| Id | Title | Status |')
    [void]$sb.AppendLine('|----|-------|--------|')
    foreach ($s in $inv.Slices) {
      [void]$sb.AppendLine(("| {0} | {1} | `{2}` |" -f $s.Id, ($s.Title -replace '\|', '/'), $s.Status))
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine(('- Done: **{0}** · Pending: **{1}** · In-progress: **{2}** · Blocked: **{3}**' -f `
        $inv.Done.Count, $inv.Pending.Count, $inv.InProgress.Count, $inv.Blocked.Count))
  } else {
    [void]$sb.AppendLine('_Could not parse slice headings from ledger.md (expected `## SC-NN — title [status]`)._')
  }
  [void]$sb.AppendLine('')

  [void]$sb.AppendLine('## Incomplete / missing from this run')
  [void]$sb.AppendLine('')
  $missing = @()
  if ($inv) {
    $missing = @($inv.Pending) + @($inv.InProgress) + @($inv.Blocked)
  }
  if ($missing.Count) {
    foreach ($s in $missing) {
      [void]$sb.AppendLine(("- `{0}` **{1}** — {2}" -f $s.Status, $s.Id, $s.Title))
    }
  } else {
    [void]$sb.AppendLine('- No pending / in-progress / blocked slices left in the ledger parse.')
  }
  [void]$sb.AppendLine('')

  [void]$sb.AppendLine('## Final Check Tail')
  [void]$sb.AppendLine('')
  if ($finalTail.Count) {
    [void]$sb.AppendLine('```text')
    foreach ($line in $finalTail) { [void]$sb.AppendLine($line) }
    [void]$sb.AppendLine('```')
  } else {
    [void]$sb.AppendLine('_No final check output captured._')
  }
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('## Recent Runner Log')
  [void]$sb.AppendLine('')
  if ($recent.Count) {
    [void]$sb.AppendLine('```text')
    foreach ($line in $recent) { [void]$sb.AppendLine($line) }
    [void]$sb.AppendLine('```')
  } else {
    [void]$sb.AppendLine('_No runner log captured._')
  }
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('## Required follow-up (orchestrator)')
  [void]$sb.AppendLine('')
  if ($Outcome -eq 'complete' -and $finalGreen) {
    [void]$sb.AppendLine('- AutoPro finalizer is green for this ledger. Review the red **STILL TO DO** block before production.')
  } else {
    [void]$sb.AppendLine('- Resolve the outcome above, fix blocked slices / env, then re-arm AutoPro or finish manually with `work`.')
  }
  [void]$sb.AppendLine('- Open `AUTOPRO-NEEDS-YOU.md` if the supervisor raised a needs-you alert.')
  [void]$sb.AppendLine('- Show Time does **not** open PRs or deploy — use `ship-epic` / your deploy path.')

  # --- RED STILL TO DO (always last) ---
  $red = Format-StillTodoRedHtml -Items @($stillTodo | Select-Object -Unique) -Outcome $Outcome
  [void]$sb.AppendLine($red)

  New-Item -ItemType Directory -Force -Path (Split-Path $handoverPath -Parent) | Out-Null
  Set-Content -LiteralPath $handoverPath -Value $sb.ToString() -Encoding utf8
  Log ("handover: wrote {0}" -f $handoverPath)

  # Always notify on non-complete; on complete still write a softer complete event to chat inbox.
  if ($Outcome -ne 'complete') {
    try {
      $null = Invoke-SupervisorNeedsYou -Kind $Outcome -Summary ("AutoPro stopped: {0}" -f $Outcome) `
        -Detail $Notes -HandoverPath $handoverPath
    } catch {}
  } else {
    try {
      $null = Send-AutoproSupervisorAlert -ScratchDir $scratch -Kind 'complete' `
        -Summary ("AutoPro complete: {0} — review STILL TO DO (red) in handover" -f $LedgerTitle) `
        -Detail ("Handover: {0}" -f $handoverPath) -SessionId $SessionId -RepoDir $RepoDir `
        -HandoverPath $handoverPath -LogPath $log -Extra @{ outcome = 'complete'; finalGreen = $finalGreen } `
        -NeedsHuman:$false
    } catch {}
  }
  return $handoverPath
}

function Publish-Handover([string]$Path, [string]$Outcome) {
  if ($NoShowTime -or -not (Test-Path -LiteralPath $Path)) { return }
  $text = Get-Content -LiteralPath $Path -Raw
  $body = @{
    id          = "repo_${SessionId}_$Outcome"
    force       = $true
    deliver     = $true
    sessionId   = $SessionId
    repoId      = [IO.Path]::GetFileName($RepoDir.TrimEnd('\', '/'))
    topic       = $LedgerTitle
    reason      = $Outcome
    text        = $text
    handoverPath = $Path
  }
  $null = Invoke-ShowTimeApi -Method POST -Path '/api/handovers' -Body $body
}

function Invoke-Slice {
  param(
    [Parameter(Mandatory = $true, Position = 0)]
    [AllowEmptyString()]
    [object]$Prompt
  )
  # Coerce steers + prompt to a single string (Log/API can leak Object[] into the pipeline).
  $steerPrefix = Get-SteersText
  if ($steerPrefix -is [System.Array]) {
    $steerPrefix = [string](($steerPrefix | ForEach-Object { [string]$_ } | Select-Object -Last 1))
  } else {
    $steerPrefix = [string]$steerPrefix
  }
  if ($Prompt -is [System.Array]) {
    $promptText = [string](($Prompt | ForEach-Object { [string]$_ }) -join "`n")
  } else {
    $promptText = [string]$Prompt
  }
  $fullPrompt = $steerPrefix + $promptText
  $preview = if ($promptText.Length -gt 80) { $promptText.Substring(0, 80) + '…' } else { $promptText }
  $eng = $script:EngineId
  $null = Log ("spawn: {0} `"$preview`" (cwd=$WorkDir)" -f $eng)
  Invoke-ShowTime -Action heartbeat -Status running -Progress -Sentinel ("Spawn {0} for slice work" -f $eng)

  $startSha = ''
  try {
    Push-Location -LiteralPath $WorkDir
    $startSha = ("$(git rev-parse HEAD 2>$null)").Trim()
  } catch {}
  finally { Pop-Location }

  $sliceExit = 0
  # Detached + no TTY: without skip-permissions the worker waits forever on tool prompts.
  if (-not $SkipPermissions) {
    throw 'REFUSE: Invoke-Slice without -SkipPermissions would hang unattended on permission prompts'
  }
  $processResult = Invoke-WorkerProcess -Prompt $fullPrompt -ModelName $Model -LogPrefix '  | ' -HeartbeatLabel 'slice live' -Resolution $script:WorkerResolution
  $sliceExit = $processResult.ExitCode
  $text = $processResult.Text
  $sec = [Math]::Max(0.5, $processResult.Seconds)
  if ($text -match "unknown option\s+'?-") {
    $argvFail = ("{0} argv parse failed — refuse to spin: {1}" -f $eng, $Matches[0])
    try {
      Write-SessionState -State 'blocked' -Outcome 'worker-argv-parse-failed'
      Invoke-ShowTime -Action heartbeat -Status blocked -StopReason 'worker argv parse failed' -Sentinel $argvFail
    } catch {}
    Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    throw $argvFail
  }
  # Prefer cross-engine parser; fall back to Claude-tuned Parse-UsageFromText
  $usageObj = if ($processResult.Usage) { $processResult.Usage } else { Parse-WorkerUsageFromText -Text $text -Engine $eng }
  $usage = Parse-UsageFromText $text
  if ($usageObj.measured) {
    $usage = @{
      input = [int]$usageObj.input; output = [int]$usageObj.output; measured = $true
      cacheCreate = [int]$usageObj.cacheCreate; cacheRead = [int]$usageObj.cacheRead
      costUsd = [double]$usageObj.costUsd; model = [string]$usageObj.model
    }
  } elseif ($usageObj.model -and -not $usage.model) {
    $usage.model = $usageObj.model
  }
  $delta = Get-GitDelta $startSha

  # Token saver: monolith re-reads prior outputs
  $priorOut = 0
  foreach ($o in $script:Stats.outputHistory) { $priorOut += $o }
  $R = 0.85
  $sliceMono = $usage.input + $usage.output + [int]($R * $priorOut)
  $script:Stats.outputHistory.Add([int]$usage.output) | Out-Null
  $script:Stats.input += $usage.input
  $script:Stats.output += $usage.output
  $script:Stats.total += ($usage.input + $usage.output)
  $script:Stats.monolithEst += $sliceMono
  $script:Stats.cacheCreate += [int]$usage.cacheCreate
  $script:Stats.cacheRead += [int]$usage.cacheRead
  $script:Stats.costUsd += [double]$usage.costUsd
  $script:Stats.modelSec += $sec
  if ($usage.measured) { $script:Stats.measured = $true }
  # Prefer real model id from worker JSON so the board never shows bare "default"
  if ($usage.model -and [string]$usage.model) {
    $script:Stats.model = [string]$usage.model
    if ($script:Stats.modelSource -match 'pending-' -or -not $script:Stats.modelSource) {
      $script:Stats.modelSource = 'worker-result'
    }
  }
  $script:Stats.filesCreated += $delta.filesCreated
  $script:Stats.filesTouched += $delta.filesTouched
  $script:Stats.linesAdded += $delta.linesAdded
  $script:Stats.linesDeleted += $delta.linesDeleted
  $script:Stats.perSlice.Add([pscustomobject]@{
      input = $usage.input; output = $usage.output; sec = [Math]::Round($sec, 1)
      costUsd = [Math]::Round([double]$usage.costUsd, 4)
      filesCreated = $delta.filesCreated; linesAdded = $delta.linesAdded
      tokPerSec = [Math]::Round(($usage.input + $usage.output) / $sec, 2)
    }) | Out-Null

  Log ("  stats> in={0} out={1} cacheR={2} cacheW={3} cost=`${4} sec={5:n1} files+={6} lines+={7} measured={8}" -f $usage.input, $usage.output, $usage.cacheRead, $usage.cacheCreate, $usage.costUsd, $sec, $delta.filesCreated, $delta.linesAdded, $usage.measured)
  # The worker committed its own slice (the `work` skill does it). Nothing to do here.
  $cAfter = Get-Counts
  $sliceNote = "Slice wall {0:n0}s · +{1} lines · tokens {2}" -f $sec, $delta.linesAdded, ($usage.input + $usage.output)
  if ($cAfter) {
    $sliceNote += (" · done={0} pending={1} blocked={2}" -f $cAfter.Done, $cAfter.Pending, $cAfter.Blocked)
  }
  Invoke-StatusLog -Action event -Level done -Event $sliceNote
  Invoke-ShowTime -Action heartbeat -Status paused -SliceComplete -Sentinel $sliceNote
  return [pscustomobject]@{
    Text     = $text
    ExitCode = $sliceExit
    StartSha = $startSha
    Usage    = $usage
    Delta    = $delta
    Seconds  = $sec
  }
}

# --- main ---
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
# Persist PID immediately so launch boot-wait / status can detect silent death
# before the first armed: line (silent-start class).
Write-SessionState -State 'booting'
Log '==== autopro runner starting ===='
Log ("sessionId={0}" -f $SessionId)
Log ("runnerPid={0}" -f $PID)
Log ("workDir={0}" -f $WorkDir)
Log ("primaryRepo={0}" -f $RepoDir)
Log ("ledgerHash={0}" -f $LedgerHash)
Log ("ledgerTitle={0}" -f $LedgerTitle)
Log ("skipPermissions={0}" -f $(if ($SkipPermissions) { '1' } else { '0' }))
Log ("allowModelOnlyFinalCheck={0}" -f $(if ($AllowModelOnlyFinalCheck) { '1' } else { '0' }))
# Resolve worker model early so Show Time can warn about credit burn
$modelRes = Resolve-WorkerModelLabel
if ($modelRes.Model) {
  $script:Stats.model = $modelRes.Model
  $script:Stats.modelSource = $modelRes.Source
} else {
  $script:Stats.model = ''
  $script:Stats.modelSource = 'pending-worker-result'
}
if ($VerifierModel -and $VerifierModel.Trim()) {
  $script:Stats.verifierModel = $VerifierModel.Trim()
} else {
  $script:Stats.verifierModel = $script:Stats.model
}
$script:Stats.engine = $script:EngineId
$script:Stats.engineDisplay = [string]$script:WorkerResolution.Display
$script:Stats.verifierEngine = $script:VerifierEngineId
try {
  $null = Save-EngineChoice -ScratchDir $scratch -Engine $script:EngineId -Model $script:Stats.model `
    -SessionId $SessionId -Display $script:WorkerResolution.Display
} catch {}
Log ("workerEngine={0} display={1} requested={2}" -f $script:EngineId, $script:WorkerResolution.Display, $Engine)
Log ("workerModel={0} source={1}" -f $(if ($script:Stats.model) { $script:Stats.model } else { '(pending first worker result)' }), $script:Stats.modelSource)
Log ("sliceVerifier={0} verifierEngine={1} verifierModel={2} repairAttempts={3}" -f $(if ($NoSliceVerifier) { 'off' } else { 'on' }), $script:VerifierEngineId, $(if ($script:Stats.verifierModel) { $script:Stats.verifierModel } else { 'same-as-worker' }), $VerifierRepairAttempts)
Log ("engineRisk={0}" -f (Get-EngineRiskLabel -Engine $script:EngineId))
Log ("maxSliceMinutes={0}" -f $(if ($MaxSliceMinutes -gt 0) { $MaxSliceMinutes } else { 'off' }))

# Detached runner has no TTY. Without unattended flags, the first tool call waits forever.
if (-not $SkipPermissions) {
  Log 'FATAL: -SkipPermissions required for detached runner (no TTY). Exiting before first worker spawn.'
  try {
    Invoke-ShowTime -Action heartbeat -Status blocked -StopReason 'No SkipPermissions (would hang)' -Sentinel 'Refused: no skip-permissions'
  } catch {}
  Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
  Write-SessionState -State 'blocked' -Outcome 'no-skip-permissions'
  Log '==== autopro runner exited (refused) ===='
  exit 64
}

# Fail before burning slices if merge would be impossible (no independent gate).
$gateSpec = Resolve-IndependentFinalGate -WorkDir $WorkDir
Log ("independentGate kind={0} display={1}" -f $gateSpec.Kind, $gateSpec.Display)
if ($gateSpec.Kind -eq 'none' -and -not $AllowModelOnlyFinalCheck) {
  Log 'FATAL: no independent final gate configured — merge would block after all slices. Set AUTOPRO_FINAL_CHECK_CMD, scripts/final-check.ps1, package.json scripts.gate, or pass -AllowModelOnlyFinalCheck.'
  try {
    Invoke-ShowTime -Action heartbeat -Status blocked -StopReason 'No independent final gate' -Sentinel 'Refused: no independent gate'
  } catch {}
  Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
  Write-SessionState -State 'blocked' -Outcome 'no-independent-gate'
  Log '==== autopro runner exited (refused) ===='
  exit 78
}
if (-not $NoSliceVerifier -and (-not (Test-Path -LiteralPath $SliceVerifierPs1) -or -not (Get-Command Test-SliceVerificationGreen -ErrorAction SilentlyContinue))) {
  Log 'FATAL: post-slice verifier policy helper is missing. Refusing to run an unverified ledger.'
  try {
    Invoke-ShowTime -Action heartbeat -Status blocked -StopReason 'Slice verifier missing' -Sentinel 'Refused: no post-slice verifier'
  } catch {}
  Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
  Write-SessionState -State 'blocked' -Outcome 'no-slice-verifier'
  Log '==== autopro runner exited (refused) ===='
  exit 78
}
Write-SessionState -State 'running'
$c = Get-Counts
if ($null -eq $c) { Log 'ABORT: no ledger.md'; exit 1 }
if (-not $c.Approved) { Log 'ABORT: ledger not Approved: yes'; exit 1 }
if (-not (Test-Path -LiteralPath $flag)) { Log 'ABORT: autopro-on flag missing'; exit 1 }

Invoke-ShowTime -Action register -Status running -Sentinel ("Runner armed · engine={0} · branch={1} · no git authority" -f $script:EngineId, (Get-CurrentBranch))
Invoke-StatusLog -Action event -Level info -Event ("Runner armed · engine={0} · branch={1} · Show Time runs zero git" -f $script:EngineId, (Get-CurrentBranch))
# Board URL is logged once at launch (SHOWTIME_URL / status server event). Do not re-emit a hardcoded 8770 here.
Invoke-StatusLog -Action event -Level server -Event ("Autopro log: {0}" -f $log)

$totalSlices = $c.Pending + $c.InProgress + $c.Blocked + $c.Done
$maxIters = $totalSlices + 2
Log ("armed: {0} slices, cap={1} iterations" -f $totalSlices, $maxIters)

$iter = 0
# Consecutive slices with no ledger progress + no code delta → abort (log class 03:01 argv spin).
$script:ZeroProgressStreak = 0
$ZeroProgressLimit = 2
while ($true) {
  $iter++
  if (-not (Test-Path -LiteralPath $flag)) {
    Log 'STOP: autopro-on deleted (kill switch)'
    Invoke-ShowTime -Action heartbeat -Status paused -StopReason 'Kill switch' -Sentinel 'Flag deleted'
    break
  }
  if ($iter -gt $maxIters) {
    Log ("STOP: iteration cap ({0}) hit" -f $maxIters)
    Invoke-ShowTime -Action heartbeat -Status stalled -StopReason 'Iteration cap' -Sentinel 'Iteration cap hit'
    break
  }

  $c = Get-Counts
  if ($null -eq $c) { Log 'STOP: ledger vanished'; break }

  # Board nudge while blocked: if operator nudged, clear board stall and keep
  # looping only when ledger is not truly [blocked] — real blocked slices still stop.
  $nudgeFlagPath = Join-Path ($env:USERPROFILE ?? $HOME) ".claude/scratch/autopro-theater/steer/${SessionId}.nudge"
  $hasNudge = Test-Path -LiteralPath $nudgeFlagPath

  if ($c.Blocked -gt 0) {
    if ($hasNudge) {
      Log ("nudge: ledger still has {0} [blocked] slice(s) — not auto-unblocking; inject steer into finalizer/work if any pending" -f $c.Blocked)
      # Do not break immediately on nudge alone when blocked — still stop; operator must edit ledger.
    }
    Log ("STOP: {0} slice(s) [blocked]" -f $c.Blocked)
    Invoke-StatusLog -Action event -Level block -Event ("{0} slice(s) [blocked] — runner stopped" -f $c.Blocked)
    Invoke-ShowTime -Action heartbeat -Status blocked -StopReason 'Ledger has blocked slices' -Sentinel 'Blocked slice detected'
    $hp = Write-Handover -Outcome 'ledger-blocked' -Notes ("{0} slice(s) marked [blocked] in ledger.md — edit reasons, then re-arm." -f $c.Blocked)
    Publish-Handover -Path $hp -Outcome 'ledger-blocked'
    Write-SessionState -State 'blocked' -Outcome 'ledger-blocked' -Handover $hp
    break
  }

  if ($hasNudge) {
    Log 'nudge: flag present — next slice will include OPERATOR NUDGE / messages'
    Invoke-ShowTime -Action heartbeat -Status running -Progress -Sentinel 'Operator nudge received — continuing'
  }

  if ($c.Pending -eq 0 -and $c.InProgress -eq 0) {
    if ($c.Done -eq 0) { Log 'STOP: empty/template ledger'; break }
    Log ("COMPLETE: {0} slices done -- final check" -f $c.Done)
    Write-SessionState -State 'finalizing' -Outcome 'final-check'
    Invoke-ShowTime -Action heartbeat -Status running -Progress -Sentinel 'Final check starting'
    $finalPrompt = @'
The autopro ledger is 100 percent complete. Invoke the check skill across the epic touched surface.
You MUST include exactly one machine-readable line:
FINAL_CHECK_STATUS=green
or
FINAL_CHECK_STATUS=red
If green, also say Epic complete, check green, and list the commits.
If red, list each failure.
Do NOT ship. Do NOT loop. This is the autopro completion step.
Note: autopro will ALSO run an independent local gate (npm run gate / final-check script /
AUTOPRO_FINAL_CHECK_CMD). Your marker alone does not authorize completion.
'@
    $finalCheck = Invoke-Slice $finalPrompt
    $finalGreen = Test-FinalCheckGreen $finalCheck
    if (-not $finalGreen) {
      Log ("FINALIZER_STOP: final check not green (exit={0})" -f $finalCheck.ExitCode)
      $hp = Write-Handover -Outcome 'final-check-not-green' -FinalCheck $finalCheck -Notes 'Final check did not emit FINAL_CHECK_STATUS=green or exited non-zero.'
      Publish-Handover -Path $hp -Outcome 'final-check-not-green'
      Write-SessionState -State 'blocked' -Outcome 'final-check-not-green' -Handover $hp
      Invoke-StatusLog -Action event -Level block -Event ("Final check not green; handover={0}" -f $hp)
      Invoke-ShowTime -Action heartbeat -Status blocked -StopReason 'Final check not green' -Sentinel ("Final check not green · handover {0}" -f $hp)
      Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
      break
    }

    # Independent gate: real process exit code, not model prose
    Log 'FINALIZER: running independent final gate…'
    Invoke-ShowTime -Action heartbeat -Status running -Progress -Sentinel 'Independent final gate'
    $indepGate = Invoke-IndependentFinalGate -WorkDir $WorkDir -AllowModelOnly:$AllowModelOnlyFinalCheck
    Log ("FINALIZER: independent gate kind={0} display={1} exit={2} ok={3}" -f $indepGate.Kind, $indepGate.Display, $indepGate.ExitCode, $indepGate.Ok)
    if ($indepGate.Text) {
      foreach ($line in ($indepGate.Text -split "`r?`n" | Select-Object -First 40)) {
        if ($line) { Log ("  gate| {0}" -f $line) }
      }
    }
    if (-not $indepGate.Ok) {
      Log ("FINALIZER_STOP: independent gate failed (kind={0} exit={1})" -f $indepGate.Kind, $indepGate.ExitCode)
      $hp = Write-Handover -Outcome 'independent-gate-failed' -FinalCheck $finalCheck -Notes ("Independent gate failed: kind={0} exit={1} display={2}`n{3}" -f $indepGate.Kind, $indepGate.ExitCode, $indepGate.Display, $indepGate.Text)
      Publish-Handover -Path $hp -Outcome 'independent-gate-failed'
      Write-SessionState -State 'blocked' -Outcome 'independent-gate-failed' -Handover $hp
      Invoke-StatusLog -Action event -Level block -Event ("Independent gate failed; handover={0}" -f $hp)
      Invoke-ShowTime -Action heartbeat -Status blocked -StopReason 'Independent gate failed' -Sentinel ("Independent gate failed · handover {0}" -f $hp)
      Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
      break
    }

    # No finish step: nothing was isolated, so nothing needs bringing home. The
    # worker's commits are already on the operator's branch.
    Write-SessionState -State 'finalizing' -Outcome 'reporting'
    Invoke-StatusLog -Action event -Level finish -Event 'Ledger complete · final check green · no merge (Show Time runs zero git)'

    $hp = Write-Handover -Outcome 'complete' -FinalCheck $finalCheck -Notes 'Final check green. No merge: Show Time runs zero git — the work is already committed on the repo branch.'
    $handoverText = ''
    try { $handoverText = Get-Content -LiteralPath $hp -Raw -ErrorAction Stop } catch {}
    # proof artifact
    try {
      $proofDir = Join-Path $RepoDir '.claude/scratch/operator-live/proof'
      New-Item -ItemType Directory -Force -Path $proofDir | Out-Null
      $proof = @{
        sessionId = $SessionId
        stats     = (Build-StatsPayload)
        repoDir   = $RepoDir
        ledgerHash = $LedgerHash
        ledgerTitle = $LedgerTitle
        handoverPath = $hp
        at        = (Get-Date).ToString('o')
      }
      $proof | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $proofDir "token-saver-$SessionId.json") -Encoding utf8
    } catch {}
    Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    Write-SessionState -State 'complete' -Outcome 'complete' -Handover $hp
    Invoke-ShowTime -Action complete -Sentinel ("Complete · handover {0}" -f $hp) -HandoverText $handoverText
    Log 'DISARMED: autopro-on removed. Loop finished (final check green + handover written; no merge — Show Time runs zero git).'
    break
  }

  $status = 'pending={0} in-progress={1} done={2}' -f $c.Pending, $c.InProgress, $c.Done
  Log ('iter {0}/{1} : {2} -> work' -f $iter, $maxIters, $status)
  Invoke-ShowTime -Action heartbeat -Status running -Progress -Sentinel ("iter $iter/$maxIters $status")
  $doneBefore = $c.Done
  $pendingBefore = $c.Pending
  $sliceInfo = Get-NextSliceInfo
  $sliceResult = $null
  try {
    # Explicit work-skill brief — bare "work" often yields empty/idle sessions
    # (in=1 out=1). Instruct the next pending ledger slice end-to-end.
    $workPrompt = @"
You are an AutoPro unattended worker (engine=$($script:EngineId)). Execute the work skill now in this repo.

You are committing DIRECTLY to the operator's checked-out branch ($(Get-CurrentBranch)) in their
working tree. There is no worktree, no scratch branch, and no safety net: nothing
will merge your work anywhere afterwards, and nothing will clean it up. Your commit
IS the deliverable. Commit only the files your slice touched — anything else you
touch, you are touching in the operator's live tree.

1. Read .claude/scratch/ledger.md (must be Approved: yes).
2. Take the FIRST slice that is [pending] or [in-progress] (not [done]/[blocked]).
3. Implement that slice fully: edit files, run checks, mark [done] with commit hash.
4. Commit only that slice's files with a conventional message.
5. Do NOT start the next slice. Stop after one slice.
6. Do not wait for a human. If blocked, mark the slice [blocked] with a short reason and exit.
7. Stay inside the current working directory. No force-push. No branch switching. No deleting .git.

If no pending slices remain, report all done and stop.
"@
    $sliceResult = Invoke-Slice $workPrompt
  } catch {
    Log ("STOP: Invoke-Slice threw: {0}" -f $_.Exception.Message)
    Write-SessionState -State 'blocked' -Outcome 'slice-throw'
    Invoke-ShowTime -Action heartbeat -Status blocked -StopReason 'Slice threw' -Sentinel $_.Exception.Message
    $hp = Write-Handover -Outcome 'slice-throw' -Notes $_.Exception.Message
    Publish-Handover -Path $hp -Outcome 'slice-throw'
    Write-SessionState -State 'blocked' -Outcome 'slice-throw' -Handover $hp
    Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    break
  }

  # Fresh verifier session follows every implementation session. UI changes
  # cannot advance without a real Playwright screenshot and zero browser errors.
  # A red result gets a bounded fresh repair session, then the verifier runs again.
  $verificationBlocked = $false
  if (-not $NoSliceVerifier) {
    $verifyResult = $null
    $verifyStartSha = if ($sliceResult) { [string]$sliceResult.StartSha } else { '' }
    for ($verifyAttempt = 1; $verifyAttempt -le ($VerifierRepairAttempts + 1); $verifyAttempt++) {
      $verifyResult = Invoke-SliceVerification -StartSha $verifyStartSha -SliceId $sliceInfo.Id -SliceTitle $sliceInfo.Title -Attempt $verifyAttempt
      if ($verifyResult.Green) { break }

      # AC5 — files=0 short-circuit. When the worker landed NO files for this
      # slice, a repair session has nothing to fix: it exits in <2s with 0
      # tokens and re-reds instantly (the SC-03 incident). Block immediately
      # with an honest message instead of burning a useless repair attempt.
      $landedFiles = @($verifyResult.ChangedFiles).Count
      if ($landedFiles -eq 0) {
        $verificationBlocked = $true
        $noFilesMsg = "Worker landed no files for $($sliceInfo.Id) — nothing to repair. Re-run the slice, or mark it [done] if the repo already passes its tests."
        Log ("VERIFY_STOP: {0} landed 0 files — skipping repair loop" -f $sliceInfo.Id)
        $hp = Write-Handover -Outcome 'slice-no-files' -Notes $noFilesMsg
        Publish-Handover -Path $hp -Outcome 'slice-no-files'
        Write-SessionState -State 'blocked' -Outcome 'slice-no-files' -Handover $hp
        Invoke-StatusLog -Action event -Level block -Event ("Slice landed no files: {0}; handover={1}" -f $sliceInfo.Id, $hp)
        Invoke-ShowTime -Action heartbeat -Status blocked -StopReason 'Worker landed no files' `
          -SliceId $sliceInfo.Id -SliceState blocked -Outcome 'slice-no-files' -Sentinel $noFilesMsg
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
        break
      }

      if ($verifyAttempt -le $VerifierRepairAttempts) {
        $verifyReport = Get-SliceVerifierDecodedText $verifyResult
        if ($verifyReport.Length -gt 6000) { $verifyReport = $verifyReport.Substring($verifyReport.Length - 6000) }
        Log ("verify: RED — spawn fresh repair session {0}/{1}" -f $verifyAttempt, $VerifierRepairAttempts)
        Invoke-ShowTime -Action heartbeat -Status running -Progress -Sentinel ("Verifier RED · repair {0}/{1} · {2}" -f $verifyAttempt, $VerifierRepairAttempts, $sliceInfo.Id)
        $repairPrompt = @"
Repair ONLY the just-completed ledger slice $($sliceInfo.Id) — $($sliceInfo.Title).
Do not start or mark any other ledger slice. Read the committed diff from $verifyStartSha..HEAD
and the independent verifier report below. Fix the concrete failures, run focused checks,
keep the current slice [done], and commit only the repair. This is a fresh AutoPro repair session.

VERIFIER REPORT:
$verifyReport
"@
        try {
          $null = Invoke-Slice $repairPrompt
        } catch {
          Log ("verify: repair session threw: {0}" -f $_.Exception.Message)
        }
        continue
      }

      $verificationBlocked = $true
      $verifyReport = Get-SliceVerifierDecodedText $verifyResult
      if ($verifyReport.Length -gt 6000) { $verifyReport = $verifyReport.Substring($verifyReport.Length - 6000) }
      Log ("VERIFY_STOP: {0} remained red after {1} repair attempt(s)" -f $sliceInfo.Id, $VerifierRepairAttempts)
      $hp = Write-Handover -Outcome 'slice-verification-failed' -Notes ("Slice {0} verifier stayed red after {1} repair attempt(s).`n{2}" -f $sliceInfo.Id, $VerifierRepairAttempts, $verifyReport)
      Publish-Handover -Path $hp -Outcome 'slice-verification-failed'
      Write-SessionState -State 'blocked' -Outcome 'slice-verification-failed' -Handover $hp
      Invoke-StatusLog -Action event -Level block -Event ("Slice verifier red: {0}; handover={1}" -f $sliceInfo.Id, $hp)
      Invoke-ShowTime -Action heartbeat -Status blocked -StopReason 'Slice verification failed' `
        -SliceId $sliceInfo.Id -SliceState blocked -Outcome 'slice-verification-failed' `
        -Sentinel ("Verifier RED · {0} · handover {1}" -f $sliceInfo.Id, $hp)
      Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
      break
    }
  }
  if ($verificationBlocked) { break }

  $cAfter = Get-Counts
  $doneAfter = if ($cAfter) { $cAfter.Done } else { $doneBefore }
  $pendingAfter = if ($cAfter) { $cAfter.Pending } else { $pendingBefore }
  $lines = 0
  $files = 0
  if ($sliceResult -and $sliceResult.Delta) {
    $lines = [int]$sliceResult.Delta.linesAdded + [int]$sliceResult.Delta.linesDeleted
    $files = [int]$sliceResult.Delta.filesCreated + [int]$sliceResult.Delta.filesTouched
  }
  $ledgerMoved = ($doneAfter -gt $doneBefore) -or ($pendingAfter -lt $pendingBefore)
  $codeMoved = ($lines -gt 0) -or ($files -gt 0)
  if (-not $ledgerMoved -and -not $codeMoved) {
    $script:ZeroProgressStreak++
    Log ("zero-progress streak={0}/{1} (no ledger move, no code delta)" -f $script:ZeroProgressStreak, $ZeroProgressLimit)
    if ($script:ZeroProgressStreak -ge $ZeroProgressLimit) {
      Log 'STOP: consecutive zero-progress slices — refusing to spin the iteration cap'
      Write-SessionState -State 'blocked' -Outcome 'zero-progress-abort'
      Invoke-StatusLog -Action event -Level block -Event ("Zero-progress abort after {0} slices" -f $script:ZeroProgressStreak)
      Invoke-ShowTime -Action heartbeat -Status blocked -StopReason 'Zero-progress abort' -Sentinel 'Consecutive empty slices'
      $hp = Write-Handover -Outcome 'zero-progress-abort' -Notes ("{0} consecutive slices with no ledger move and no code delta." -f $script:ZeroProgressStreak)
      Publish-Handover -Path $hp -Outcome 'zero-progress-abort'
      Write-SessionState -State 'blocked' -Outcome 'zero-progress-abort' -Handover $hp
      Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
      break
    }
  } else {
    $script:ZeroProgressStreak = 0
  }
}

# Final session note for chat bridge (even on clean complete)
try {
  $finalState = if (Test-Path -LiteralPath $sessionStatePath) {
    (Get-Content -LiteralPath $sessionStatePath -Raw | ConvertFrom-Json)
  } else { $null }
  $outcome = if ($finalState -and $finalState.outcome) { [string]$finalState.outcome } else { 'exited' }
  if ($outcome -ne 'complete' -and $outcome -ne '') {
    # blocked paths already alerted via Write-Handover; ensure inbox has a closing line
    Log ("runner-exit outcome={0}" -f $outcome)
  } elseif ($outcome -eq 'complete') {
    Log 'runner-exit outcome=complete (no needs-you)'
  }
} catch {}
Log '==== autopro runner exited ===='
