<#
  theater-register.ps1 — Show Time session bus helpers (Looplet).
  Ensures the local Show Time server is up, then register/heartbeat/complete/unregister.
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('ensure', 'register', 'heartbeat', 'complete', 'unregister', 'url')]
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
  [switch]$Progress,
  [switch]$SliceComplete,
  [switch]$OpenBrowser,
  [int]$StallAfterSec = 300
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

  # Detach fully from parent job (UseShellExecute) so agent shells don't kill the board.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $node.Source
  $psi.Arguments = "`"$ServerJs`""
  $psi.WorkingDirectory = $SkillRoot
  $psi.UseShellExecute = $true
  $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
  [void][System.Diagnostics.Process]::Start($psi)

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
  if ($RepoId) { return $RepoId }
  if (-not $dir) { return 'repo' }
  return [IO.Path]::GetFileName($dir.TrimEnd('\', '/'))
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
      Start-Process "$u/"
    }
    Write-Output $u
    break
  }
  'register' {
    if (-not $SessionId) { $SessionId = 'sess_' + [guid]::NewGuid().ToString('N').Substring(0, 12) }
    $u = Start-ShowTimeServer
    if (-not $LedgerPath -and $RepoDir) {
      $LedgerPath = Join-Path $RepoDir '.claude\scratch\ledger.md'
    }
    if (-not $LogPath -and $Root) {
      $LogPath = Join-Path $Root '.claude\scratch\autopro.log'
    }
    if (-not $Branch) { $Branch = Get-GitBranch $RepoDir }
    $body = @{
      sessionId   = $SessionId
      repoId      = (Get-RepoIdFromPath $RepoDir)
      repoPath    = $RepoDir
      branch      = $Branch
      status      = $Status
      pid         = $RunnerPid
      ledgerPath  = $LedgerPath
      ledgerHash  = $LedgerHash
      ledgerTitle = $LedgerTitle
      logPath     = $LogPath
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
    $result = Invoke-ShowTimeJson -Method POST -Url "$u/api/sessions" -Body $body
    if ($OpenBrowser) { Start-Process "$u/" }
    Write-Output ($result.session | ConvertTo-Json -Depth 6 -Compress)
    Write-Output "SHOWTIME_URL=$u/"
    Write-Output "SESSION_ID=$SessionId"
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
    $result = Invoke-ShowTimeJson -Method POST -Url "$u/api/sessions/$SessionId/heartbeat" -Body $body
    Write-Output ($result.session | ConvertTo-Json -Depth 6 -Compress)
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
