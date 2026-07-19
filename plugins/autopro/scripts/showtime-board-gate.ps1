# showtime-board-gate.ps1 — P0: board must stay truthful or arm fails closed.
# Dot-source from launch-showtime.ps1, launch-ultra.ps1, autopro-runner.ps1.
#
# Contract:
#   - Unattended arm (risk switches / OpenRegister) MUST leave a visible session.
#   - JOIN_REQUIRES_APPROVAL is healed via join+approve when AllowAutoApprove.
#   - Heartbeat 404 → re-ensure once; still missing → caller treats as hard error when RequireBoard.

$script:ShowTimeStateRoot = Join-Path ($env:USERPROFILE ?? $HOME) '.claude/scratch/autopro-theater'
$script:ShowTimePortFile = Join-Path $script:ShowTimeStateRoot 'server.port'
$script:ShowTimeTokenFile = Join-Path $script:ShowTimeStateRoot 'server.token'

function Get-BoardBaseUrl {
  if (-not (Test-Path -LiteralPath $script:ShowTimePortFile)) { return $null }
  $p = (Get-Content -LiteralPath $script:ShowTimePortFile -Raw).Trim()
  if ($p -notmatch '^\d+$') { return $null }
  return "http://127.0.0.1:$p"
}

function Get-BoardToken {
  if (-not (Test-Path -LiteralPath $script:ShowTimeTokenFile)) { return '' }
  return (Get-Content -LiteralPath $script:ShowTimeTokenFile -Raw).Trim()
}

function Invoke-BoardApi {
  param(
    [Parameter(Mandatory = $true)][ValidateSet('GET', 'POST', 'DELETE')][string]$Method,
    [Parameter(Mandatory = $true)][string]$Path,
    [hashtable]$Body = $null,
    [int]$TimeoutSec = 10
  )
  $base = Get-BoardBaseUrl
  $tok = Get-BoardToken
  if (-not $base) { throw 'BOARD_DOWN: no Show Time port (server not running?)' }
  if (-not $tok) { throw 'BOARD_DOWN: no Show Time token' }
  $params = @{
    Uri             = "$base$Path"
    Method          = $Method
    UseBasicParsing = $true
    TimeoutSec      = $TimeoutSec
    Headers         = @{ 'X-Showtime-Token' = $tok }
  }
  if ($null -ne $Body) {
    $params.ContentType = 'application/json'
    $params.Body = ($Body | ConvertTo-Json -Depth 12 -Compress)
  }
  try {
    $resp = Invoke-WebRequest @params
    if (-not $resp.Content) { return $null }
    return ($resp.Content | ConvertFrom-Json)
  } catch {
    $msg = $_.Exception.Message
    $detail = ''
    try {
      if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = [string]$_.ErrorDetails.Message }
    } catch {}
    $err = "BOARD_API $Method $Path failed: $msg"
    if ($detail) { $err += " | $detail" }
    $ex = [System.Exception]::new($err)
    if ($detail -match 'JOIN_REQUIRES_APPROVAL') { $ex.Data['code'] = 'JOIN_REQUIRES_APPROVAL' }
    if ($msg -match '404') { $ex.Data['code'] = 'NOT_FOUND' }
    if ($msg -match '403') { $ex.Data['code'] = 'FORBIDDEN' }
    throw $ex
  }
}

function Test-BoardSessionPresent {
  param([Parameter(Mandatory = $true)][string]$SessionId)
  try {
    $r = Invoke-BoardApi -Method GET -Path '/api/sessions'
    $list = @()
    if ($r.sessions) { $list = @($r.sessions) }
    elseif ($r -is [array]) { $list = @($r) }
    foreach ($s in $list) {
      if ([string]$s.sessionId -eq $SessionId) { return $true }
    }
    return $false
  } catch {
    return $false
  }
}

function Ensure-BoardJoinApproved {
  <#
    Join + auto-approve so unattended arms can POST /api/sessions.
    Returns PSCustomObject { ok, joinId, status, error }
  #>
  param(
    [Parameter(Mandatory = $true)][string]$SessionId,
    [Parameter(Mandatory = $true)][string]$RepoPath,
    [string]$Branch = 'main',
    [string]$LedgerPath = '',
    [string]$LedgerTitle = '',
    [string]$LedgerHash = '',
    [string]$LogPath = '',
    [int]$RunnerPid = 0
  )
  $repoId = [IO.Path]::GetFileName($RepoPath.TrimEnd('\', '/'))
  $joinBody = @{
    sessionId         = $SessionId
    repoId            = $repoId
    repoPath          = $RepoPath
    branch            = $Branch
    statusDesired     = 'running'
    pid               = $RunnerPid
    ledgerPath        = $LedgerPath
    ledgerHash        = $LedgerHash
    ledgerTitle       = $LedgerTitle
    logPath           = $LogPath
    primaryRepoPath   = $RepoPath
  }
  try {
    $jr = Invoke-BoardApi -Method POST -Path '/api/join-requests' -Body $joinBody
  } catch {
    return [pscustomobject]@{ ok = $false; joinId = ''; status = 'error'; error = $_.Exception.Message }
  }
  $status = [string]$jr.status
  $jid = $null
  if ($jr.request -and $jr.request.id) { $jid = [string]$jr.request.id }
  elseif ($jr.id) { $jid = [string]$jr.id }

  if ($status -eq 'pending' -and $jid) {
    try {
      $ap = Invoke-BoardApi -Method POST -Path "/api/join-requests/$jid/approve" -Body @{ by = 'board-gate-auto' }
      return [pscustomobject]@{
        ok     = $true
        joinId = $jid
        status = 'approved'
        error  = ''
        session = $ap.session
      }
    } catch {
      return [pscustomobject]@{ ok = $false; joinId = $jid; status = 'approve_failed'; error = $_.Exception.Message }
    }
  }
  if ($status -in @('approved', 'already_on_board')) {
    return [pscustomobject]@{ ok = $true; joinId = $jid; status = $status; error = ''; session = $jr.session }
  }
  return [pscustomobject]@{ ok = $false; joinId = $jid; status = $status; error = "unexpected join status $status" }
}

function Assert-BoardSessionRegistered {
  <#
    Fail-closed for unattended arms: session must be listable on the board.
    When -AllowAutoApprove, attempt join+approve then optional register body.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$SessionId,
    [Parameter(Mandatory = $true)][string]$RepoPath,
    [string]$Branch = 'main',
    [string]$LedgerPath = '',
    [string]$LedgerTitle = '',
    [string]$LedgerHash = '',
    [string]$LogPath = '',
    [int]$RunnerPid = 0,
    [switch]$AllowAutoApprove,
    [hashtable]$RegisterBody = $null,
    [int]$Retries = 3
  )

  for ($i = 0; $i -lt $Retries; $i++) {
    if (Test-BoardSessionPresent -SessionId $SessionId) {
      return [pscustomobject]@{ ok = $true; healed = ($i -gt 0); error = '' }
    }
    if (-not $AllowAutoApprove) { break }

    $join = Ensure-BoardJoinApproved -SessionId $SessionId -RepoPath $RepoPath -Branch $Branch `
      -LedgerPath $LedgerPath -LedgerTitle $LedgerTitle -LedgerHash $LedgerHash `
      -LogPath $LogPath -RunnerPid $RunnerPid
    if (-not $join.ok) {
      Start-Sleep -Milliseconds 400
      continue
    }

    # Materialize / refresh session row
    $body = if ($RegisterBody) { $RegisterBody } else {
      @{
        sessionId   = $SessionId
        repoPath    = $RepoPath
        repoId      = [IO.Path]::GetFileName($RepoPath.TrimEnd('\', '/'))
        branch      = $Branch
        status      = 'running'
        pid         = $RunnerPid
        ledgerPath  = $LedgerPath
        ledgerTitle = $LedgerTitle
        ledgerHash  = $LedgerHash
        logPath     = $LogPath
      }
    }
    try {
      $null = Invoke-BoardApi -Method POST -Path '/api/sessions' -Body $body
    } catch {
      # 403 still = join race; retry
      Start-Sleep -Milliseconds 500
      continue
    }
    if (Test-BoardSessionPresent -SessionId $SessionId) {
      return [pscustomobject]@{ ok = $true; healed = $true; error = '' }
    }
    Start-Sleep -Milliseconds 500
  }

  return [pscustomobject]@{
    ok     = $false
    healed = $false
    error  = "BOARD_DESYNC: session $SessionId not on Show Time after join/approve/register. UI would lie — arm refused (fail-closed)."
  }
}
