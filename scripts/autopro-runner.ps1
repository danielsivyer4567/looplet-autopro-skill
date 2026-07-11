<#
  autopro-runner.ps1 -- headless ledger loop + Show Time v2 heartbeats / stats / steers.
#>
param(
  [string]$Root = (Get-Location).Path,
  [string]$RepoDir = (Get-Location).Path,
  [string]$WorktreeDir = '',
  [string]$BaseBranch = '',
  [ValidateSet('base', 'main')]
  [string]$MergeTarget = 'base',
  [string]$MainBranch = '',
  [string]$Model = '',
  [string]$LedgerHash = '',
  [string]$LedgerTitle = '',
  [string]$SessionId = '',
  [switch]$NoShowTime,
  [switch]$NoWorktree,
  [switch]$PushOnFinish
)

$ErrorActionPreference = 'Stop'
$scratch = Join-Path $Root '.claude\scratch'
# Primary ledger (operator source of truth)
$ledgerPrimary = Join-Path $RepoDir '.claude\scratch\ledger.md'
$flag = Join-Path $scratch 'autopro-on'
$log = Join-Path $scratch 'autopro.log'
$sessionStatePath = Join-Path $scratch 'autopro-session.json'
$handoverPath = Join-Path $scratch 'SHOWTIME-HANDOVER.md'
$RegisterPs1 = Join-Path $PSScriptRoot 'theater-register.ps1'
$WorktreePs1 = Join-Path $PSScriptRoot 'showtime-worktree.ps1'
$CommitPs1 = Join-Path $PSScriptRoot 'showtime-scoped-commit.ps1'
$StatusPs1 = Join-Path $PSScriptRoot 'showtime-status.ps1'
$StateRoot = Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater'
$PortFile = Join-Path $StateRoot 'server.port'

# Merge gate lives in one place, shared with test-showtime.ps1
. (Join-Path $PSScriptRoot 'showtime-final-check.ps1')

# Code workdir = isolated worktree when available
$WorkDir = if ($WorktreeDir -and (Test-Path -LiteralPath $WorktreeDir)) { $WorktreeDir } else { $RepoDir }
$ledger = if (Test-Path (Join-Path $WorkDir '.claude\scratch\ledger.md')) {
  Join-Path $WorkDir '.claude\scratch\ledger.md'
} else { $ledgerPrimary }

# Accumulated session stats
$script:Stats = @{
  model = if ($Model) { $Model } else { 'default' }
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
  Write-Output $line
}

function Get-ShowTimeUrl {
  if (-not (Test-Path -LiteralPath $PortFile)) { return $null }
  $p = (Get-Content -LiteralPath $PortFile -Raw).Trim()
  if ($p -notmatch '^\d+$') { return $null }
  return "http://127.0.0.1:$p"
}

function Get-ShowTimeToken {
  $tf = Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater\server.token'
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
    Log ("  showtime> warn: {0}" -f $_.Exception.Message)
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
  return @{
    model    = $script:Stats.model
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
    [string]$HandoverText = ''
  )
  if ($NoShowTime) { return }
  $body = @{
    status     = $Status
    ledgerPath = $ledger
    ledgerHash = $LedgerHash
    ledgerTitle = $LedgerTitle
    handoverPath = $handoverPath
    logPath    = $log
    pid        = $PID
    stats      = (Build-StatsPayload)
  }
  if ($StopReason) { $body.stopReason = $StopReason }
  if ($Progress) { $body.progress = $true }
  if ($SliceComplete) { $body.sliceComplete = $true }
  if ($Sentinel) { $body.sentinelEntry = @{ text = $Sentinel; level = 'info' } }
  if ($HandoverText) { $body.handoverText = $HandoverText }

  if ($Action -eq 'register') {
    if (-not $SessionId) { throw 'SessionId required for Show Time register (join gate)' }
    $body.sessionId = $SessionId
    # Real repo name from primary RepoDir — never worktree sess_* leaf
    $repoName = [IO.Path]::GetFileName($RepoDir.TrimEnd('\', '/'))
    if ($repoName -match '^sess_' -or $repoName -eq 'repo' -or -not $repoName) {
      $parent = Split-Path $RepoDir -Parent
      if ($parent) { $repoName = [IO.Path]::GetFileName($parent.TrimEnd('\', '/')) }
    }
    if ($WorkDir -match '(?i)[\\/]\.worktrees-showtime[\\/]') {
      $primary = ($WorkDir -replace '(?i)[\\/]\.worktrees-showtime[\\/].*$', '')
      $rn = [IO.Path]::GetFileName($primary.TrimEnd('\', '/'))
      if ($rn) { $repoName = $rn }
    }
    if (-not $repoName -or $repoName -eq 'repo' -or $repoName -match '^sess_') {
      throw "repo name required for register (got '$repoName')"
    }
    $body.repoId = $repoName
    $body.repoPath = $WorkDir
    try {
      Push-Location $WorkDir
      $body.branch = ("$(git rev-parse --abbrev-ref HEAD 2>$null)").Trim()
    } catch { $body.branch = '' }
    finally { Pop-Location }
    if (-not $body.branch -or $body.branch -eq 'HEAD') {
      throw 'branch required for Show Time register (join gate)'
    }
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

function Get-SteersText {
  $r = Invoke-ShowTimeApi -Method POST -Path "/api/sessions/$SessionId/consume-steers" -Body @{}
  if (-not $r -or -not $r.steers) { return '' }
  $parts = @()
  foreach ($st in $r.steers) {
    $parts += ("OPERATOR STEER ({0}): {1}" -f $st.target, $st.text)
  }
  if ($parts.Count -eq 0) { return '' }
  return ($parts -join "`n") + "`n`n"
}

function Sync-LedgerToPrimary {
  try {
    if ($ledger -ne $ledgerPrimary -and (Test-Path -LiteralPath $ledger)) {
      $destDir = Split-Path $ledgerPrimary -Parent
      New-Item -ItemType Directory -Force -Path $destDir | Out-Null
      Copy-Item -LiteralPath $ledger -Destination $ledgerPrimary -Force
    }
  } catch {}
}

function Sync-LedgerToWork {
  try {
    if ($ledger -ne $ledgerPrimary -and (Test-Path -LiteralPath $ledgerPrimary)) {
      $destDir = Split-Path $ledger -Parent
      New-Item -ItemType Directory -Force -Path $destDir | Out-Null
      Copy-Item -LiteralPath $ledgerPrimary -Destination $ledger -Force
    }
  } catch {}
}

function Invoke-ScopedCommit([string]$msg) {
  if ($NoWorktree) { return [pscustomobject]@{ Ok = $true; Status = 'skipped-no-worktree'; Commit = '' } }
  if (-not $WorkDir -or $WorkDir -eq $RepoDir) { return [pscustomobject]@{ Ok = $true; Status = 'skipped-primary'; Commit = '' } }
  if (-not (Test-Path -LiteralPath $CommitPs1)) { return [pscustomobject]@{ Ok = $false; Status = 'missing-commit-script'; Commit = '' } }
  try {
    $out = & pwsh -NoProfile -File $CommitPs1 -WorktreeDir $WorkDir -SessionId $SessionId -Message $msg 2>&1
    $exit = $LASTEXITCODE
    $out | ForEach-Object { Log ("  commit> {0}" -f $_) }
    $status = ''
    $commit = ''
    foreach ($line in $out) {
      if ("$line" -match '^STATUS=(.+)$') { $status = $Matches[1].Trim() }
      if ("$line" -match '^COMMIT=(.+)$') { $commit = $Matches[1].Trim() }
    }
    return [pscustomobject]@{ Ok = ($exit -eq 0); Status = $status; Commit = $commit; ExitCode = $exit }
  } catch {
    Log ("  commit> warn: {0}" -f $_.Exception.Message)
    return [pscustomobject]@{ Ok = $false; Status = 'exception'; Commit = ''; Error = $_.Exception.Message; ExitCode = 1 }
  }
}

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
      '-LedgerPath', $ledgerPrimary,
      '-MergeTarget', $MergeTarget,
      '-WorktreeDir', $WorkDir
    )
    if ($Event) { $statusArgs += @('-Event', $Event, '-Level', $Level) }
    if ($Commit) { $statusArgs += @('-Commit', $Commit) }
    & pwsh @statusArgs 2>&1 | ForEach-Object { Log ("  status> {0}" -f $_) }
  } catch {
    Log ("  status> warn: {0}" -f $_.Exception.Message)
  }
}

function Invoke-FinishMergeAndPrune {
  if ($NoWorktree) {
    Log 'finish: skipped (NoWorktree) — no isolated merge/prune'
    return [pscustomobject]@{ Ok = $true; Status = 'skipped-no-worktree'; MergeCommit = ''; WorktreeRemoved = $false }
  }
  if (-not (Test-Path -LiteralPath $WorktreePs1)) {
    Log 'finish: showtime-worktree.ps1 missing'
    return [pscustomobject]@{ Ok = $false; Status = 'missing-worktree-script'; MergeCommit = ''; WorktreeRemoved = $false }
  }
  # Final scoped commit of any remaining dirty files in worktree
  $finalCommit = Invoke-ScopedCommit "showtime ${SessionId}: final scoped commit before merge"
  if (-not $finalCommit.Ok) {
    return [pscustomobject]@{ Ok = $false; Status = "final-commit-$($finalCommit.Status)"; MergeCommit = ''; WorktreeRemoved = $false; FinalCommit = $finalCommit }
  }
  $finishArgs = @(
    '-NoProfile', '-File', $WorktreePs1,
    '-Action', 'finish',
    '-RepoDir', $RepoDir,
    '-SessionId', $SessionId,
    '-MergeTarget', $MergeTarget
  )
  if ($BaseBranch) { $finishArgs += @('-BaseBranch', $BaseBranch) }
  if ($MainBranch) { $finishArgs += @('-MainBranch', $MainBranch) }
  if ($PushOnFinish) { $finishArgs += '-Push' }
  Log ("finish: merge session branch (target={0}) + prune worktree/branch" -f $MergeTarget)
  $finishOut = & pwsh @finishArgs 2>&1
  $finishExit = $LASTEXITCODE
  $finishOut | ForEach-Object { Log ("  finish> {0}" -f $_) }
  $mergeCommit = ''
  $status = ''
  $worktreeRemoved = $false
  foreach ($line in $finishOut) {
    if ("$line" -match '^(MERGE_COMMIT|COMMIT|SHA)=(.+)$') { $mergeCommit = $Matches[2].Trim() }
    if ("$line" -match '^STATUS=(.+)$') { $status = $Matches[1].Trim() }
    if ("$line" -match '^WORKTREE_REMOVED=(.+)$') { $worktreeRemoved = $true }
  }
  $ok = ($finishExit -eq 0 -and $status -eq 'merged-and-pruned' -and ($NoWorktree -or $worktreeRemoved))
  Invoke-StatusLog -Action event -Level finish -Event ("Session finish · merge target={0} · status={1} · ok={2}" -f $MergeTarget, $status, $ok) -Commit $mergeCommit
  # Also prune any other READY showtime worktrees
  try {
    & pwsh -NoProfile -File $WorktreePs1 -Action prune -RepoDir $RepoDir -StaleDays 7 2>&1 |
      ForEach-Object { Log ("  prune> {0}" -f $_) }
  } catch {
    Log ("  prune> warn: {0}" -f $_.Exception.Message)
  }
  return [pscustomobject]@{
    Ok              = $ok
    Status          = $status
    ExitCode        = $finishExit
    MergeCommit     = $mergeCommit
    WorktreeRemoved = $worktreeRemoved
    FinalCommit     = $finalCommit
    Output          = @($finishOut)
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

function Parse-UsageFromText([string]$text) {
  # JSON-first: `claude -p --output-format json` puts the truth in the result
  # object's usage block. The old first-regex-match approach missed cache
  # tokens entirely (~2/3 of real input) and ignored total_cost_usd.
  $in = 0; $out = 0; $cacheCreate = 0; $cacheRead = 0; $cost = 0.0; $measured = $false
  foreach ($line in ($text -split "`r?`n")) {
    $l = $line.Trim()
    # Runner log lines prefix claude stdout with "  | " — strip before probing.
    if ($l -match '^\|\s*(.+)$') { $l = $Matches[1].Trim() }
    if (-not ($l.StartsWith('{') -and $l.EndsWith('}'))) { continue }
    $obj = $null
    try { $obj = $l | ConvertFrom-Json -ErrorAction Stop } catch { continue }
    foreach ($node in @($obj)) {
      if ($node.type -ne 'result' -or $null -eq $node.usage) { continue }
      $u = $node.usage
      $in = [int]($u.input_tokens ?? 0)
      $out = [int]($u.output_tokens ?? 0)
      $cacheCreate = [int]($u.cache_creation_input_tokens ?? 0)
      $cacheRead = [int]($u.cache_read_input_tokens ?? 0)
      if ($null -ne $node.total_cost_usd) { $cost = [double]$node.total_cost_usd }
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
  if (-not $measured) {
    $in = [Math]::Max(1, [int]($text.Length / 4))
    $out = [Math]::Max(1, [int]($text.Length / 8))
  }
  return @{
    input = $in; output = $out; measured = $measured
    cacheCreate = $cacheCreate; cacheRead = $cacheRead; costUsd = $cost
  }
}

function Get-RecentLogLines([int]$Count = 80) {
  if (-not (Test-Path -LiteralPath $log)) { return @() }
  return @(Get-Content -LiteralPath $log -Tail $Count -ErrorAction SilentlyContinue)
}

function Write-SessionState([string]$State, [string]$Outcome = '', [string]$Handover = '') {
  try {
    $obj = [ordered]@{
      sessionId    = $SessionId
      state        = $State
      outcome      = $Outcome
      ledgerHash   = $LedgerHash
      ledgerTitle  = $LedgerTitle
      repoDir      = $RepoDir
      workDir      = $WorkDir
      mergeTarget  = $MergeTarget
      handoverPath = $Handover
      updatedAt    = (Get-Date).ToString('o')
    }
    $obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sessionStatePath -Encoding utf8
  } catch {}
}

function Write-Handover {
  param(
    [Parameter(Mandatory = $true)][string]$Outcome,
    [object]$FinalCheck = $null,
    [object]$Merge = $null,
    [string]$Notes = ''
  )
  $counts = Get-Counts
  $stats = Build-StatsPayload
  $finalExit = if ($FinalCheck) { [int]$FinalCheck.ExitCode } else { -1 }
  $finalGreen = if ($FinalCheck) { Test-FinalCheckGreen $FinalCheck } else { $false }
  $mergeOk = if ($Merge) { [bool]$Merge.Ok } else { $false }
  $mergeStatus = if ($Merge) { [string]$Merge.Status } else { '' }
  $mergeCommit = if ($Merge) { [string]$Merge.MergeCommit } else { '' }
  $recent = Get-RecentLogLines 80
  $finalTail = @()
  if ($FinalCheck -and $FinalCheck.Text) {
    $finalTail = @(([string]$FinalCheck.Text -split "`r?`n") | Select-Object -Last 80)
  }

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('# SHOWTIME HANDOVER')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine("| | |")
  [void]$sb.AppendLine("|--|--|")
  [void]$sb.AppendLine("| Session | ``$SessionId`` |")
  [void]$sb.AppendLine("| Outcome | ``$Outcome`` |")
  [void]$sb.AppendLine("| Ledger | $LedgerTitle |")
  [void]$sb.AppendLine("| Ledger hash | ``$LedgerHash`` |")
  [void]$sb.AppendLine("| Repo | ``$RepoDir`` |")
  [void]$sb.AppendLine("| Worktree | ``$WorkDir`` |")
  [void]$sb.AppendLine("| Merge target | ``$MergeTarget`` |")
  [void]$sb.AppendLine("| Final check exit | ``$finalExit`` |")
  [void]$sb.AppendLine("| Final check green | ``$finalGreen`` |")
  [void]$sb.AppendLine("| Merge ok | ``$mergeOk`` |")
  [void]$sb.AppendLine("| Merge status | ``$mergeStatus`` |")
  [void]$sb.AppendLine("| Merge commit | ``$mergeCommit`` |")
  [void]$sb.AppendLine("| Generated | ``$((Get-Date).ToString('o'))`` |")
  if ($counts) {
    [void]$sb.AppendLine("| Counts | done=$($counts.Done), pending=$($counts.Pending), in-progress=$($counts.InProgress), blocked=$($counts.Blocked) |")
  }
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('## Summary')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine("- Outcome: ``$Outcome``")
  [void]$sb.AppendLine("- Handover was written before board completion/clear.")
  [void]$sb.AppendLine("- Token stats: input=$($stats.tokens.input), output=$($stats.tokens.output), total=$($stats.tokens.total), saved=$($stats.tokens.saved)")
  if ($Notes) { [void]$sb.AppendLine("- Notes: $Notes") }
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
  [void]$sb.AppendLine('## Required Follow-up')
  [void]$sb.AppendLine('')
  if ($Outcome -eq 'complete') {
    [void]$sb.AppendLine('- None from AutoPro finalizer.')
  } else {
    [void]$sb.AppendLine('- Resolve the finalizer outcome above before considering this ledger complete.')
  }

  New-Item -ItemType Directory -Force -Path (Split-Path $handoverPath -Parent) | Out-Null
  Set-Content -LiteralPath $handoverPath -Value $sb.ToString() -Encoding utf8
  Log ("handover: wrote {0}" -f $handoverPath)
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

function Invoke-Slice($prompt) {
  Sync-LedgerToWork
  $steerPrefix = Get-SteersText
  $fullPrompt = $steerPrefix + $prompt
  Log ("spawn: claude -p `"$prompt`" (cwd=$WorkDir)")
  Invoke-ShowTime -Action heartbeat -Status running -Progress -Sentinel "Spawn claude -p for slice work"

  $startSha = ''
  try {
    Push-Location -LiteralPath $WorkDir
    $startSha = ("$(git rev-parse HEAD 2>$null)").Trim()
  } catch {}
  finally { Pop-Location }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $buf = New-Object System.Text.StringBuilder
  $sliceExit = 0
  # Mid-slice keep-alive: JSON-mode claude -p often emits nothing until exit, so
  # line-matched heartbeats never fire and the board false-stalled at 300s.
  $hbJob = $null
  if (-not $NoShowTime) {
    try {
      $hbJob = Start-ThreadJob -ScriptBlock {
        param($SessionId, $StateRoot, $LedgerPath, $LedgerHash, $LedgerTitle, $HandoverPath, $LogPath, $RunnerPid)
        $ErrorActionPreference = 'SilentlyContinue'
        $portFile = Join-Path $StateRoot 'server.port'
        $tokFile = Join-Path $StateRoot 'server.token'
        while ($true) {
          Start-Sleep -Seconds 60
          try {
            if (-not (Test-Path -LiteralPath $portFile)) { continue }
            $port = (Get-Content -LiteralPath $portFile -Raw).Trim()
            $tok = if (Test-Path -LiteralPath $tokFile) { (Get-Content -LiteralPath $tokFile -Raw).Trim() } else { '' }
            $headers = @{ Authorization = "Bearer $tok"; 'X-Showtime-Token' = $tok; 'Content-Type' = 'application/json' }
            # Consume steers / ORCH NUDGE mid-slice so reconnect pings land while model runs
            $nudgeAck = $false
            try {
              $cs = Invoke-RestMethod -Method POST -Uri "http://127.0.0.1:$port/api/sessions/$SessionId/consume-steers" -Headers $headers -Body '{}' -TimeoutSec 5
              foreach ($st in @($cs.steers)) {
                $t = [string]$st.text
                $k = [string]$st.kind
                if ($k -eq 'nudge' -or $t -match 'ORCH NUDGE') { $nudgeAck = $true }
              }
            } catch {}
            $sentText = if ($nudgeAck) { 'nudge ack · reconnected' } else { 'slice keep-alive (model still running)' }
            $body = @{
              status      = 'running'
              progress    = $true
              pid         = $RunnerPid
              ledgerPath  = $LedgerPath
              ledgerHash  = $LedgerHash
              ledgerTitle = $LedgerTitle
              handoverPath = $HandoverPath
              logPath     = $LogPath
              sentinelEntry = @{ text = $sentText; level = 'info' }
            } | ConvertTo-Json -Compress -Depth 6
            Invoke-RestMethod -Method POST -Uri "http://127.0.0.1:$port/api/sessions/$SessionId/heartbeat" -Headers $headers -Body $body -TimeoutSec 5 | Out-Null
          } catch {}
        }
      } -ArgumentList @($SessionId, (Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater'), $ledger, $LedgerHash, $LedgerTitle, $handoverPath, $log, $PID)
    } catch {
      Log ("  warn: mid-slice heartbeat job not started: $($_.Exception.Message)")
    }
  }
  Push-Location -LiteralPath $WorkDir
  try {
    $claudeArgs = @('-p', $fullPrompt, '--verbose', '--dangerously-skip-permissions', '--output-format', 'json')
    if ($Model) { $claudeArgs = @('-p', $fullPrompt, '--model', $Model, '--verbose', '--dangerously-skip-permissions', '--output-format', 'json') }
    & claude @claudeArgs 2>&1 | ForEach-Object {
      $line = "$_"
      [void]$buf.AppendLine($line)
      Log ("  | {0}" -f $line)
      if ($line -match 'done|commit|SC-|slice|check|token') {
        try { Invoke-ShowTime -Action heartbeat -Status running -Progress } catch {}
      }
    }
    $sliceExit = $LASTEXITCODE
  } finally {
    Pop-Location
    if ($hbJob) {
      try { Stop-Job -Job $hbJob -Force -ErrorAction SilentlyContinue } catch {}
      try { Remove-Job -Job $hbJob -Force -ErrorAction SilentlyContinue } catch {}
    }
  }
  $sw.Stop()
  $sec = [Math]::Max(0.5, $sw.Elapsed.TotalSeconds)
  $text = $buf.ToString()
  $usage = Parse-UsageFromText $text
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
  # Scoped commit inside worktree only (never primary dirty tree)
  $sliceCommit = Invoke-ScopedCommit "showtime ${SessionId}: slice commit"
  Sync-LedgerToPrimary
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
    Usage    = $usage
    Delta    = $delta
    Seconds  = $sec
    Commit   = $sliceCommit
  }
}

# --- main ---
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
Log '==== autopro runner starting ===='
Log ("sessionId={0}" -f $SessionId)
Log ("workDir={0}" -f $WorkDir)
Log ("primaryRepo={0}" -f $RepoDir)
Log ("ledgerHash={0}" -f $LedgerHash)
Log ("ledgerTitle={0}" -f $LedgerTitle)
Write-SessionState -State 'running'
$c = Get-Counts
if ($null -eq $c) { Log 'ABORT: no ledger.md'; exit 1 }
if (-not $c.Approved) { Log 'ABORT: ledger not Approved: yes'; exit 1 }
if (-not (Test-Path -LiteralPath $flag)) { Log 'ABORT: autopro-on flag missing'; exit 1 }

Invoke-ShowTime -Action register -Status running -Sentinel ("Runner armed · worktree isolation={0}" -f (-not $NoWorktree -and $WorkDir -ne $RepoDir))
Invoke-StatusLog -Action event -Level info -Event ("Runner armed · isolation={0} · merge={1}" -f (-not $NoWorktree -and $WorkDir -ne $RepoDir), $MergeTarget)
# Board URL is logged once at launch (SHOWTIME_URL / status server event). Do not re-emit a hardcoded 8770 here.
Invoke-StatusLog -Action event -Level server -Event ("Autopro log: {0}" -f $log)

$totalSlices = $c.Pending + $c.InProgress + $c.Blocked + $c.Done
$maxIters = $totalSlices + 2
Log ("armed: {0} slices, cap={1} iterations" -f $totalSlices, $maxIters)

$iter = 0
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

  if ($c.Blocked -gt 0) {
    Log ("STOP: {0} slice(s) [blocked]" -f $c.Blocked)
    Invoke-StatusLog -Action event -Level block -Event ("{0} slice(s) [blocked] — runner stopped" -f $c.Blocked)
    Invoke-ShowTime -Action heartbeat -Status blocked -StopReason 'Ledger has blocked slices' -Sentinel 'Blocked slice detected'
    break
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

    Write-SessionState -State 'finalizing' -Outcome 'merge-prune'
    $merge = Invoke-FinishMergeAndPrune
    if (-not $merge.Ok) {
      Log ("FINALIZER_STOP: merge/prune failed status={0} exit={1}" -f $merge.Status, $merge.ExitCode)
      $hp = Write-Handover -Outcome 'merge-prune-failed' -FinalCheck $finalCheck -Merge $merge -Notes 'Worktree was preserved for manual resolution.'
      Publish-Handover -Path $hp -Outcome 'merge-prune-failed'
      Write-SessionState -State 'blocked' -Outcome 'merge-prune-failed' -Handover $hp
      Invoke-StatusLog -Action event -Level block -Event ("Merge/prune failed ({0}); handover={1}" -f $merge.Status, $hp)
      Invoke-ShowTime -Action heartbeat -Status blocked -StopReason ("Merge/prune failed: {0}" -f $merge.Status) -Sentinel ("Merge/prune failed · handover {0}" -f $hp)
      Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
      break
    }

    $hp = Write-Handover -Outcome 'complete' -FinalCheck $finalCheck -Merge $merge -Notes 'Final check green, merge verified, worktree pruned.'
    $handoverText = ''
    try { $handoverText = Get-Content -LiteralPath $hp -Raw -ErrorAction Stop } catch {}
    # proof artifact
    try {
      $proofDir = Join-Path $RepoDir '.claude\scratch\operator-live\proof'
      New-Item -ItemType Directory -Force -Path $proofDir | Out-Null
      $proof = @{
        sessionId = $SessionId
        stats     = (Build-StatsPayload)
        workDir   = $WorkDir
        ledgerHash = $LedgerHash
        ledgerTitle = $LedgerTitle
        handoverPath = $hp
        merge = $merge
        at        = (Get-Date).ToString('o')
      }
      $proof | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $proofDir "token-saver-$SessionId.json") -Encoding utf8
    } catch {}
    Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    Write-SessionState -State 'complete' -Outcome 'complete' -Handover $hp
    Invoke-ShowTime -Action complete -Sentinel ("Complete · handover {0} · merge {1}" -f $hp, $merge.MergeCommit) -HandoverText $handoverText
    Log 'DISARMED: autopro-on removed. Loop finished (handover + merge + prune verified).'
    break
  }

  $status = 'pending={0} in-progress={1} done={2}' -f $c.Pending, $c.InProgress, $c.Done
  Log ('iter {0}/{1} : {2} -> work' -f $iter, $maxIters, $status)
  Invoke-ShowTime -Action heartbeat -Status running -Progress -Sentinel ("iter $iter/$maxIters $status")
  Invoke-Slice 'work'
}

Log '==== autopro runner exited ===='
