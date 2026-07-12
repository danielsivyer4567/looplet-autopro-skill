<#
  theater-register.ps1 — Show Time session bus helpers (Looplet).
  Ensures the local Show Time server is up, then register/heartbeat/complete/unregister.
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('ensure', 'register', 'request-join', 'join-status', 'heartbeat', 'complete', 'unregister', 'url')]
  [string]$Action,

  [string]$SessionId = '',
  [string]$RepoDir = '',
  [string]$Root = '',
  [string]$RepoId = '',
  [string]$Branch = '',
  [string]$Status = 'running',
  [int]$RunnerPid = 0,
  [string]$LedgerPath = '',
  [string]$LedgerHash = '',
  [string]$LedgerTitle = '',
  [string]$LogPath = '',
  [string]$HandoverPath = '',
  [string]$HandoverText = '',
  # Multi-engine credit visibility (optional; runner also heartbeats stats)
  [string]$Engine = '',
  [string]$Model = '',
  [string]$VerifierEngine = '',
  [string]$VerifierModel = '',
  [switch]$Progress,
  [switch]$SliceComplete,
  [switch]$OpenBrowser,
  [int]$StallAfterSec = 900,
  [int]$WaitSec = 20,
  [switch]$OpenRegister,
  [switch]$SkipWait
)

$ErrorActionPreference = 'Stop'
# .../autopro/scripts -> skill root is parent
$SkillRoot = Split-Path $PSScriptRoot -Parent
$ServerJs = Join-Path $SkillRoot 'scripts\theater-server.mjs'
$StateRoot = Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater'
$PortFile = Join-Path $StateRoot 'server.port'
$PreferredPort = 8770

function Get-ShowTimeBaseUrl {
  if (Test-Path -LiteralPath $PortFile) {
    $p = (Get-Content -LiteralPath $PortFile -Raw).Trim()
    if ($p -match '^\d+$') {
      try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$p/api/health" -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200) { return "http://127.0.0.1:$p" }
      } catch {}
    }
  }
  return $null
}

function Start-ShowTimeServer {
  $existing = Get-ShowTimeBaseUrl
  if ($existing) { return $existing }

  New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (-not $node) { throw 'node is required for Show Time server' }

  # Detach OUTSIDE the parent Job Object. Start-Process with RedirectStandard*
  # keeps the board inside agent/CI jobs — parent exit kills :8770 mid-run
  # (seen as connection-refused heartbeats while codex keeps working).
  # Win32_Process.Create is the same durable detach as launch-showtime runner.
  $cmdLine = '"{0}" "{1}"' -f $node.Source, $ServerJs
  $started = $false
  try {
    $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
      CommandLine      = $cmdLine
      CurrentDirectory = $SkillRoot
    }
    if ($created.ReturnValue -eq 0 -and $created.ProcessId) {
      Write-Output ("SHOWTIME_PID={0}" -f $created.ProcessId)
      Write-Output 'SHOWTIME_DETACH=Win32_Process.Create'
      $started = $true
    }
  } catch {
    Write-Output ("SHOWTIME_DETACH_WARN {0}" -f $_.Exception.Message)
  }
  if (-not $started) {
    try {
      $p = Start-Process -FilePath $node.Source `
        -ArgumentList @($ServerJs) `
        -WorkingDirectory $SkillRoot `
        -WindowStyle Hidden `
        -PassThru
      if ($p) {
        Write-Output "SHOWTIME_PID=$($p.Id)"
        Write-Output 'SHOWTIME_DETACH=Start-Process'
      }
    } catch {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $node.Source
      $psi.Arguments = "`"$ServerJs`""
      $psi.WorkingDirectory = $SkillRoot
      $psi.UseShellExecute = $true
      $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
      [void][System.Diagnostics.Process]::Start($psi)
      Write-Output 'SHOWTIME_DETACH=UseShellExecute'
    }
  }

  for ($i = 0; $i -lt 50; $i++) {
    Start-Sleep -Milliseconds 200
    $u = Get-ShowTimeBaseUrl
    if ($u) { return $u }
  }
  throw 'Show Time server failed to start (no health on preferred ports).'
}

function Get-ShowTimeToken {
  $tf = Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater\server.token'
  if (Test-Path -LiteralPath $tf) { return (Get-Content -LiteralPath $tf -Raw).Trim() }
  return ''
}

function Invoke-ShowTimeJson {
  param([string]$Method, [string]$Url, [hashtable]$Body = $null)
  $params = @{
    Uri             = $Url
    Method          = $Method
    UseBasicParsing = $true
    TimeoutSec      = 5
    Headers         = @{ 'X-Showtime-Token' = (Get-ShowTimeToken) }
  }
  if ($null -ne $Body) {
    $params.ContentType = 'application/json'
    $params.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
  }
  $resp = Invoke-WebRequest @params
  return ($resp.Content | ConvertFrom-Json)
}

function Get-GitBranch([string]$dir) {
  if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return '' }
  try {
    Push-Location -LiteralPath $dir
    $b = & git rev-parse --abbrev-ref HEAD 2>$null
    return "$b".Trim()
  } catch { return '' }
  finally { Pop-Location }
}

function Get-RepoIdFromPath([string]$dir) {
  if ($RepoId -and $RepoId -ne 'repo' -and $RepoId -notmatch '^sess_') { return $RepoId }
  if (-not $dir) { return '' }
  $p = $dir.TrimEnd('\', '/')
  # Worktree: …\<repo>\.worktrees-showtime\<sess_*> → real repo folder name
  if ($p -match '(?i)[\\/]\.worktrees-showtime[\\/]') {
    $parent = ($p -replace '(?i)[\\/]\.worktrees-showtime[\\/].*$', '')
    $name = [IO.Path]::GetFileName($parent.TrimEnd('\', '/'))
    if ($name -and $name -ne 'repo' -and $name -notmatch '^sess_') { return $name }
  }
  $leaf = [IO.Path]::GetFileName($p)
  if ($leaf -match '^sess_' -or $leaf -eq 'repo' -or -not $leaf) { return '' }
  return $leaf
}

# Operator call 2026-07-12: board opens in GOOGLE CHROME first, default browser only if absent
function Open-BoardUrl([string]$url) {
  foreach ($c in @(
      "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
      "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
      "${env:LOCALAPPDATA}\Google\Chrome\Application\chrome.exe"
    )) {
    if (Test-Path -LiteralPath $c) {
      try { Start-Process -FilePath $c -ArgumentList @($url); return } catch {}
    }
  }
  try { Start-Process $url } catch {}
}

switch ($Action) {
  'url' {
    $u = Get-ShowTimeBaseUrl
    if (-not $u) { $u = Start-ShowTimeServer }
    Write-Output $u
    break
  }
  'ensure' {
    $u = Start-ShowTimeServer
    if ($OpenBrowser) {
      Open-BoardUrl "$u/"
    }
    Write-Output $u
    break
  }
  'request-join' {
    if (-not $SessionId) { throw 'SessionId required for request-join' }
    $u = Start-ShowTimeServer
    if (-not $LedgerPath -and $RepoDir) {
      $LedgerPath = Join-Path $RepoDir '.claude\scratch\ledger.md'
    }
    if (-not $LogPath -and $Root) {
      $LogPath = Join-Path $Root '.claude\scratch\autopro.log'
    }
    if (-not $Branch) { $Branch = Get-GitBranch $RepoDir }
    if (-not $Branch) { $Branch = Get-GitBranch (Split-Path $RepoDir -Parent) }
    $resolvedRepo = Get-RepoIdFromPath $RepoDir
    if (-not $resolvedRepo) { throw 'repo name required for request-join (real folder, not sess id / worktree leaf)' }
    if (-not $Branch) { throw 'branch required for request-join (join gate)' }
    $body = @{
      sessionId   = $SessionId
      repoId      = $resolvedRepo
      repoPath    = $RepoDir
      branch      = $Branch
      status      = $Status
      pid         = $RunnerPid
      ledgerPath  = $LedgerPath
      ledgerHash  = $LedgerHash
      ledgerTitle = $LedgerTitle
      logPath     = $LogPath
      ledgerKey   = $LedgerHash
      primaryRepoPath = $(if ($Root) { $Root } else { $RepoDir })
    }
    $result = Invoke-ShowTimeJson -Method POST -Url "$u/api/join-requests" -Body $body
    $status = [string]$result.status
    $joinId = $null
    if ($result.request -and $result.request.id) { $joinId = [string]$result.request.id }

    Write-Output "JOIN_STATUS=$status"
    if ($joinId) { Write-Output "JOIN_ID=$joinId" }
    Write-Output "SHOWTIME_URL=$u/"
    Write-Output "SESSION_ID=$SessionId"
    Write-Output "BOARD_APPROVE=Open http://127.0.0.1:8770/ (or Looplet Board) and Approve"

    if ($status -eq 'already_on_board' -or $status -eq 'approved') {
      if ($OpenBrowser) { Open-BoardUrl "$u/" }
      if ($result.session) { Write-Output ($result.session | ConvertTo-Json -Depth 6 -Compress) }
      break
    }
    if ($status -eq 'denied') {
      throw "Join denied by operator"
    }

    # Short wait only — never hang models for minutes
    $wait = 20
    if ($PSBoundParameters.ContainsKey('WaitSec')) { $wait = $WaitSec }
    if ($SkipWait -or $wait -le 0) {
      Write-Output 'JOIN_WAIT=skipped — pending operator approval; re-run -Action join-status later'
      break
    }
    Write-Output "JOIN_WAIT=up to ${wait}s for operator Approve (2FA-style gate)"
    $deadline = (Get-Date).AddSeconds($wait)
    while ((Get-Date) -lt $deadline) {
      if (-not $joinId) { break }
      Start-Sleep -Seconds 2
      try {
        $poll = Invoke-ShowTimeJson -Method GET -Url "$u/api/join-requests/$joinId"
        $st = [string]$poll.status
        if ($st -eq 'approved') {
          Write-Output 'JOIN_STATUS=approved'
          if ($poll.session) { Write-Output ($poll.session | ConvertTo-Json -Depth 6 -Compress) }
          if ($OpenBrowser) { Open-BoardUrl "$u/" }
          break
        }
        if ($st -eq 'denied') { throw 'Join denied by operator' }
      } catch {
        if ("$($_.Exception.Message)" -match 'denied') { throw }
      }
    }
    if ($joinId) {
      try {
        $final = Invoke-ShowTimeJson -Method GET -Url "$u/api/join-requests/$joinId"
        if ([string]$final.status -eq 'pending') {
          Write-Output 'JOIN_STATUS=pending'
          Write-Output 'JOIN_HINT=Not approved yet. Exit cleanly — re-run join-status; do not poll for 10 minutes.'
        }
      } catch {}
    }
    break
  }
  'join-status' {
    $u = Get-ShowTimeBaseUrl
    if (-not $u) { throw 'Show Time server not running' }
    if ($SessionId) {
      $all = Invoke-ShowTimeJson -Method GET -Url "$u/api/join-requests"
      $mine = @($all.requests | Where-Object { $_.sessionId -eq $SessionId } | Select-Object -Last 1)
      if (-not $mine -or -not $mine.Count) {
        try {
          $sess = Invoke-ShowTimeJson -Method GET -Url "$u/api/sessions"
          $hit = @($sess.sessions | Where-Object { $_.sessionId -eq $SessionId } | Select-Object -First 1)
          if ($hit -and $hit.Count) {
            Write-Output 'JOIN_STATUS=already_on_board'
            Write-Output ($hit[0] | ConvertTo-Json -Depth 4 -Compress)
            break
          }
        } catch {}
        Write-Output 'JOIN_STATUS=not_found'
        Write-Output 'JOIN_HINT=No join request and no board lane yet for this SessionId. Run -Action request-join (or register) to place a pending request; if you already had a lane, request-join rematerializes after Approve.'
        break
      }
      $j = $mine[0]
      Write-Output ("JOIN_STATUS={0}" -f $j.status)
      Write-Output ("JOIN_ID={0}" -f $j.id)
      try {
        $poll = Invoke-ShowTimeJson -Method GET -Url "$u/api/join-requests/$($j.id)"
        if ($poll.session) { Write-Output ($poll.session | ConvertTo-Json -Depth 6 -Compress) }
      } catch {}
      break
    }
    $all = Invoke-ShowTimeJson -Method GET -Url "$u/api/join-requests"
    Write-Output ($all | ConvertTo-Json -Depth 6 -Compress)
    break
  }
  'register' {
    # Default = request-join (operator must Approve). -OpenRegister = unattended:
    # join-request + auto-approve + POST session (prompt-and-play after risk switches).
    if (-not $OpenRegister) {
      # Re-enter request-join via recursive call of the same script
      $argList = @(
        '-NoProfile', '-File', $PSCommandPath,
        '-Action', 'request-join',
        '-SessionId', $SessionId,
        '-RepoDir', $RepoDir,
        '-Root', $Root,
        '-RepoId', $RepoId,
        '-Branch', $Branch,
        '-Status', $Status,
        '-RunnerPid', $RunnerPid,
        '-LedgerPath', $LedgerPath,
        '-LedgerHash', $LedgerHash,
        '-LedgerTitle', $LedgerTitle,
        '-LogPath', $LogPath,
        '-StallAfterSec', $StallAfterSec,
        '-WaitSec', $(if ($PSBoundParameters.ContainsKey('WaitSec')) { $WaitSec } else { 20 })
      )
      if ($OpenBrowser) { $argList += '-OpenBrowser' }
      if ($SkipWait) { $argList += '-SkipWait' }
      & pwsh @argList
      break
    }
    if (-not $SessionId) { throw 'SessionId required for register (join gate)' }
    $u = Start-ShowTimeServer
    if (-not $LedgerPath -and $RepoDir) {
      $LedgerPath = Join-Path $RepoDir '.claude\scratch\ledger.md'
    }
    if (-not $LogPath -and $Root) {
      $LogPath = Join-Path $Root '.claude\scratch\autopro.log'
    }
    if (-not $Branch) { $Branch = Get-GitBranch $RepoDir }
    if (-not $Branch) { $Branch = Get-GitBranch (Split-Path $RepoDir -Parent) }
    $resolvedRepo = Get-RepoIdFromPath $RepoDir
    if (-not $resolvedRepo) { throw 'repo name required for register (real folder, not sess id / worktree leaf)' }
    if (-not $Branch) { throw 'branch required for register (join gate)' }

    # Auto-approve path for unattended arms (same as operator clicking Approve).
    $joinBody = @{
      sessionId   = $SessionId
      repoId      = $resolvedRepo
      repoPath    = $RepoDir
      branch      = $Branch
      status      = $Status
      pid         = $RunnerPid
      ledgerPath  = $LedgerPath
      ledgerHash  = $LedgerHash
      ledgerTitle = $LedgerTitle
      logPath     = $LogPath
      ledgerKey   = $LedgerHash
      primaryRepoPath = $(if ($Root) { $Root } else { $RepoDir })
    }
    try {
      $jr = Invoke-ShowTimeJson -Method POST -Url "$u/api/join-requests" -Body $joinBody
      $jstatus = [string]$jr.status
      Write-Output ("JOIN_STATUS={0}" -f $jstatus)
      $jid = $null
      if ($jr.request -and $jr.request.id) { $jid = [string]$jr.request.id }
      if ($jstatus -eq 'pending' -and $jid) {
        $ap = Invoke-ShowTimeJson -Method POST -Url "$u/api/join-requests/$jid/approve" -Body @{ by = 'open-register' }
        Write-Output 'JOIN_STATUS=approved'
        if ($ap.session) {
          Write-Output ($ap.session | ConvertTo-Json -Depth 6 -Compress)
        }
      } elseif ($jstatus -eq 'already_on_board' -or $jstatus -eq 'approved') {
        if ($jr.session) { Write-Output ($jr.session | ConvertTo-Json -Depth 6 -Compress) }
      }
    } catch {
      Write-Output ("JOIN_WARN={0}" -f $_.Exception.Message)
    }

    $body = @{
      sessionId   = $SessionId
      repoId      = $resolvedRepo
      repoPath    = $RepoDir
      branch      = $Branch
      status      = $Status
      pid         = $RunnerPid
      ledgerPath  = $LedgerPath
      ledgerHash  = $LedgerHash
      ledgerTitle = $LedgerTitle
      logPath     = $LogPath
      ledgerKey   = $LedgerHash
      primaryRepoPath = $(if ($Root) { $Root } else { $RepoDir })
      alarms      = @{
        stallAfterSec    = $StallAfterSec
        completeEnabled  = $true
        stallEnabled     = $true
      }
      timer       = @{
        running   = ($Status -eq 'running')
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
      }
    }
    if ($Engine -or $Model) {
      $body.stats = @{
        engine         = $(if ($Engine) { $Engine } else { '' })
        model          = $(if ($Model) { $Model } else { '' })
        modelSource    = $(if ($Model) { 'register' } else { 'pending-worker-result' })
        verifierEngine = $(if ($VerifierEngine) { $VerifierEngine } else { $Engine })
        verifierModel  = $(if ($VerifierModel) { $VerifierModel } else { $Model })
      }
      if ($Engine) { $body.engine = $Engine }
    }
    try {
      $result = Invoke-ShowTimeJson -Method POST -Url "$u/api/sessions" -Body $body
      if ($result.session) { Write-Output ($result.session | ConvertTo-Json -Depth 6 -Compress) }
    } catch {
      # After approve, session may already exist from approveJoinRequest
      Write-Output ("REGISTER_WARN={0}" -f $_.Exception.Message)
    }
    if ($OpenBrowser) { Open-BoardUrl "$u/" }
    Write-Output "SHOWTIME_URL=$u/"
    Write-Output "SESSION_ID=$SessionId"
    if ($Engine) { Write-Output "ENGINE=$Engine" }
    break
  }
  'heartbeat' {
    if (-not $SessionId) { throw 'SessionId required for heartbeat' }
    $u = Get-ShowTimeBaseUrl
    if (-not $u) { $u = Start-ShowTimeServer }
    $body = @{
      status = $Status
    }
    if ($RunnerPid) { $body.pid = $RunnerPid }
    if ($Branch) { $body.branch = $Branch }
    if ($LedgerPath) { $body.ledgerPath = $LedgerPath }
    if ($LedgerHash) { $body.ledgerHash = $LedgerHash }
    if ($LedgerTitle) { $body.ledgerTitle = $LedgerTitle }
    if ($HandoverPath) { $body.handoverPath = $HandoverPath }
    if ($HandoverText) { $body.handoverText = $HandoverText }
    if ($Progress) { $body.progress = $true }
    if ($SliceComplete) { $body.sliceComplete = $true }
    if ($Engine -or $Model) {
      $body.stats = @{
        engine = $(if ($Engine) { $Engine } else { '' })
        model  = $(if ($Model) { $Model } else { '' })
      }
      if ($VerifierEngine) { $body.stats.verifierEngine = $VerifierEngine }
      if ($VerifierModel) { $body.stats.verifierModel = $VerifierModel }
    }
    try {
      $result = Invoke-ShowTimeJson -Method POST -Url "$u/api/sessions/$SessionId/heartbeat" -Body $body
      Write-Output ($result.session | ConvertTo-Json -Depth 6 -Compress)
    } catch {
      $msg = $_.Exception.Message
      if ($msg -match '404|not found' -or ($_.ErrorDetails.Message -match 'not found|SESSION_NOT_FOUND')) {
        Write-Output "JOIN_HINT=Register hit a transient 'not found' — re-registering the session onto the shared board"
        # request-join rematerializes if previously approved; else leaves pending
        $rjArgs = @(
          '-NoProfile', '-File', $PSCommandPath,
          '-Action', 'request-join',
          '-SessionId', $SessionId,
          '-RepoDir', $RepoDir,
          '-Root', $Root,
          '-RepoId', $RepoId,
          '-Branch', $Branch,
          '-Status', $Status,
          '-RunnerPid', $RunnerPid,
          '-LedgerPath', $LedgerPath,
          '-LedgerHash', $LedgerHash,
          '-LedgerTitle', $LedgerTitle,
          '-LogPath', $LogPath,
          '-WaitSec', 0,
          '-SkipWait'
        )
        & pwsh @rjArgs
        try {
          $result = Invoke-ShowTimeJson -Method POST -Url "$u/api/sessions/$SessionId/heartbeat" -Body $body
          Write-Output ($result.session | ConvertTo-Json -Depth 6 -Compress)
        } catch {
          Write-Output 'JOIN_STATUS=pending_or_missing'
          Write-Output "JOIN_HINT=Still not on board after re-register. Operator may need to Approve a join request."
          throw
        }
      } else {
        throw
      }
    }
    break
  }
  'complete' {
    if (-not $SessionId) { throw 'SessionId required for complete' }
    $u = Get-ShowTimeBaseUrl
    if (-not $u) { throw 'Show Time server not running' }
    $body = @{ status = 'complete'; progress = $true }
    if ($LedgerPath) { $body.ledgerPath = $LedgerPath }
    if ($LedgerHash) { $body.ledgerHash = $LedgerHash }
    if ($LedgerTitle) { $body.ledgerTitle = $LedgerTitle }
    if ($HandoverPath) { $body.handoverPath = $HandoverPath }
    if ($HandoverText) { $body.handoverText = $HandoverText }
    $result = Invoke-ShowTimeJson -Method POST -Url "$u/api/sessions/$SessionId/heartbeat" -Body $body
    Write-Output ($result.session | ConvertTo-Json -Depth 6 -Compress)
    break
  }
  'unregister' {
    if (-not $SessionId) { throw 'SessionId required for unregister' }
    $u = Get-ShowTimeBaseUrl
    if (-not $u) { Write-Output '{"ok":true,"skipped":true}'; break }
    try {
      $result = Invoke-ShowTimeJson -Method DELETE -Url "$u/api/sessions/$SessionId"
      Write-Output ($result | ConvertTo-Json -Compress)
    } catch {
      Write-Output '{"ok":true,"skipped":true}'
    }
    break
  }
}
