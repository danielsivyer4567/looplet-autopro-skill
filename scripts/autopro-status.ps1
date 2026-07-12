<#
  autopro-status.ps1 — one-glance health for AutoPro + Show Time.

  Prints a single summary line, then one line per known repo / live session:

    SHOWTIME  board:ok:8770  sessions:2  runners:1
    ARMED  repo=looplet crm  sess=sess_abc  runner:alive:114992  slice=SC-06  3/13  ledger=Self-repair…
    IDLE   repo=ai-sidebar   sess=-         runner:none          slice=-      -/ -  approved=yes

  Usage:
    pwsh -File autopro-status.ps1
    pwsh -File autopro-status.ps1 -RepoDir 'C:\repos\foo'
    pwsh -File autopro-status.ps1 -Json
    pwsh -File autopro-status.ps1 -Quiet   # one summary line only
#>
param(
  [string]$RepoDir = '',
  [switch]$Json,
  [switch]$Quiet,
  [switch]$EnsureBoard   # start board if down (optional)
)

$ErrorActionPreference = 'Continue'
$skillScripts = $PSScriptRoot
$stateRoot = Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater'
$portFile = Join-Path $stateRoot 'server.port'
$tokenFile = Join-Path $stateRoot 'server.token'
$sessionDir = Join-Path $stateRoot 'sessions'

function Get-BoardPort {
  $port = 8770
  if (Test-Path -LiteralPath $portFile) {
    $p = (Get-Content -LiteralPath $portFile -Raw).Trim()
    if ($p -match '^\d+$') { $port = [int]$p }
  }
  return $port
}

function Get-BoardToken {
  if (Test-Path -LiteralPath $tokenFile) {
    return (Get-Content -LiteralPath $tokenFile -Raw).Trim()
  }
  return ''
}

function Test-Board {
  $port = Get-BoardPort
  $tok = Get-BoardToken
  try {
    $h = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/health" -TimeoutSec 2
    $sessions = @()
    if ($tok) {
      try {
        $r = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/sessions" `
          -Headers @{ 'X-Showtime-Token' = $tok } -TimeoutSec 3
        $sessions = @($r.sessions)
      } catch {}
    }
    return [pscustomobject]@{
      Ok       = $true
      Port     = $port
      Label    = "ok:$port"
      Sessions = $sessions
      Error    = ''
    }
  } catch {
    return [pscustomobject]@{
      Ok       = $false
      Port     = $port
      Label    = "down:$port"
      Sessions = @()
      Error    = $_.Exception.Message
    }
  }
}

function Get-Runners {
  $list = [System.Collections.Generic.List[object]]::new()
  try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine -match 'autopro-runner\.ps1' }
    foreach ($p in @($procs)) {
      $cmd = [string]$p.CommandLine
      $sid = ''
      $root = ''
      $repo = ''
      if ($cmd -match '(?i)-SessionId\s+(?:\"([^\"]+)\"|''([^'']+)''|(\S+))') {
        $sid = $Matches[1]; if (-not $sid) { $sid = $Matches[2] }; if (-not $sid) { $sid = $Matches[3] }
      }
      if ($cmd -match '(?i)-Root\s+(?:\"([^\"]+)\"|''([^'']+)''|(\S+))') {
        $root = $Matches[1]; if (-not $root) { $root = $Matches[2] }; if (-not $root) { $root = $Matches[3] }
      }
      if ($cmd -match '(?i)-RepoDir\s+(?:\"([^\"]+)\"|''([^'']+)''|(\S+))') {
        $repo = $Matches[1]; if (-not $repo) { $repo = $Matches[2] }; if (-not $repo) { $repo = $Matches[3] }
      }
      $list.Add([pscustomobject]@{
          Pid       = $p.ProcessId
          SessionId = $sid
          Root      = $root
          RepoDir   = $repo
          Cmd       = $cmd
        }) | Out-Null
    }
  } catch {}
  return @($list)
}

function Test-PidAlive([object]$pidVal) {
  $n = 0
  try { $n = [int]$pidVal } catch { return $false }
  if ($n -le 0) { return $false }
  try {
    Get-Process -Id $n -ErrorAction Stop | Out-Null
    return $true
  } catch { return $false }
}

function Get-LedgerSnap([string]$dir) {
  $ledger = Join-Path $dir '.claude\scratch\ledger.md'
  $title = ''
  $approved = 'no'
  $done = 0; $pending = 0; $inprog = 0; $blocked = 0
  $slice = '-'
  if (-not (Test-Path -LiteralPath $ledger)) {
    return [pscustomobject]@{
      HasLedger = $false; Title = ''; Approved = 'missing'
      Done = 0; Pending = 0; InProgress = 0; Blocked = 0
      Total = 0; Slice = '-'; Path = $ledger
    }
  }
  $raw = Get-Content -LiteralPath $ledger -Raw -ErrorAction SilentlyContinue
  if (-not $raw) {
    return [pscustomobject]@{
      HasLedger = $true; Title = ''; Approved = 'empty'
      Done = 0; Pending = 0; InProgress = 0; Blocked = 0
      Total = 0; Slice = '-'; Path = $ledger
    }
  }
  $tm = [regex]::Match($raw, '(?m)^#\s+Ledger:\s*(.+)$')
  if ($tm.Success) { $title = $tm.Groups[1].Value.Trim() }
  if ($raw -match '(?im)^Approved:\s*yes') { $approved = 'yes' }
  elseif ($raw -match '(?im)^Approved:\s*(\S+)') { $approved = $Matches[1] }

  $re = [regex]'(?m)^##\s+(SC-\d+|SD-[\w-]+|H\d+|P\d+[-\w]*)\s+(?:[—–-]\s+)?(.+?)\s+\[(pending|in-progress|done|blocked)\]'
  $firstInprog = $null
  $firstPending = $null
  foreach ($m in $re.Matches($raw)) {
    $id = $m.Groups[1].Value
    $st = $m.Groups[3].Value.ToLowerInvariant()
    switch ($st) {
      'done' { $done++ }
      'pending' { $pending++; if (-not $firstPending) { $firstPending = $id } }
      'in-progress' { $inprog++; if (-not $firstInprog) { $firstInprog = $id } }
      'blocked' { $blocked++ }
    }
  }
  $slice = if ($firstInprog) { $firstInprog } elseif ($firstPending) { $firstPending } else { '-' }
  return [pscustomobject]@{
    HasLedger  = $true
    Title      = $title
    Approved   = $approved
    Done       = $done
    Pending    = $pending
    InProgress = $inprog
    Blocked    = $blocked
    Total      = $done + $pending + $inprog + $blocked
    Slice      = $slice
    Path       = $ledger
  }
}

function Get-PrimaryFromPath([string]$path) {
  if (-not $path) { return '' }
  $norm = $path.TrimEnd('\', '/')
  if ($norm -match '(?i)[\\/]\.worktrees-showtime[\\/][^\\/]+$') {
    $norm = $norm -replace '(?i)[\\/]\.worktrees-showtime[\\/][^\\/]+$', ''
  }
  return $norm
}

function Get-RepoShort([string]$path) {
  $p = Get-PrimaryFromPath $path
  if (-not $p) { return 'repo' }
  return [IO.Path]::GetFileName($p.TrimEnd('\', '/'))
}

function Find-Roots {
  $found = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  if ($RepoDir) {
    if (Test-Path -LiteralPath $RepoDir) {
      [void]$found.Add((Resolve-Path -LiteralPath $RepoDir).Path)
    } else {
      [void]$found.Add($RepoDir)
    }
  }

  # Live runners
  foreach ($r in (Get-Runners)) {
    foreach ($cand in @($r.RepoDir, $r.Root)) {
      $prim = Get-PrimaryFromPath $cand
      if ($prim -and (Test-Path -LiteralPath $prim)) { [void]$found.Add((Resolve-Path -LiteralPath $prim).Path) }
    }
  }

  # Theater sessions
  if (Test-Path -LiteralPath $sessionDir) {
    Get-ChildItem -LiteralPath $sessionDir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
      try {
        $s = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
        foreach ($cand in @($s.repoPath, $s.ledgerPath, $s.logPath)) {
          $prim = Get-PrimaryFromPath ([string]$cand)
          if ($prim -match '[\\/]\.claude[\\/]scratch') {
            $prim = $prim -replace '[\\/]\.claude[\\/]scratch.*$', ''
          }
          if ($prim -and (Test-Path -LiteralPath $prim)) {
            [void]$found.Add((Resolve-Path -LiteralPath $prim).Path)
          }
        }
      } catch {}
    }
  }

  # Common roots + known-roots.txt
  $knownFile = Join-Path $stateRoot 'known-roots.txt'
  if (Test-Path -LiteralPath $knownFile) {
    Get-Content -LiteralPath $knownFile -ErrorAction SilentlyContinue | ForEach-Object {
      $line = "$_".Trim()
      if ($line -and -not $line.StartsWith('#') -and (Test-Path -LiteralPath $line)) {
        [void]$found.Add((Resolve-Path -LiteralPath $line).Path)
      }
    }
  }
  if ($env:AUTOPRO_KNOWN_ROOTS) {
    foreach ($piece in ($env:AUTOPRO_KNOWN_ROOTS -split '[;,]')) {
      $t = $piece.Trim()
      if ($t -and (Test-Path -LiteralPath $t)) { [void]$found.Add((Resolve-Path -LiteralPath $t).Path) }
    }
  }
  foreach ($guess in @(
      'C:\LOOPLET\ai-sidebar',
      'C:\LOOPLET\ai-sidebar\extension',
      'C:\repos\looplet webb app',
      'C:\repos\looplet webb app\loopletai',
      'C:\repos\looplet webb app\looplet crm'
    )) {
    if (Test-Path -LiteralPath $guess) {
      $hasLedger = Test-Path (Join-Path $guess '.claude\scratch\ledger.md')
      $hasFlag = @(Get-ChildItem (Join-Path $guess '.claude\scratch') -Filter 'autopro-on*' -EA SilentlyContinue).Count -gt 0
      if ($hasLedger -or $hasFlag) {
        [void]$found.Add((Resolve-Path -LiteralPath $guess).Path)
      }
    }
  }

  return @($found)
}

function Get-ArmedFlags([string]$root) {
  $scratch = Join-Path $root '.claude\scratch'
  if (-not (Test-Path -LiteralPath $scratch)) { return @() }
  return @(Get-ChildItem -LiteralPath $scratch -Filter 'autopro-on*' -File -ErrorAction SilentlyContinue)
}

# --- optional ensure board ---
if ($EnsureBoard) {
  $reg = Join-Path $skillScripts 'theater-register.ps1'
  if (Test-Path -LiteralPath $reg) {
    & pwsh -NoProfile -File $reg -Action ensure 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
  }
}

$board = Test-Board
$runners = Get-Runners
$roots = Find-Roots

# Build row model
$rows = [System.Collections.Generic.List[object]]::new()

# From board sessions (authoritative when board is up)
$sessionByPrimary = @{}
foreach ($s in @($board.Sessions)) {
  $primary = Get-PrimaryFromPath ([string]$s.repoPath)
  if (-not $primary) { $primary = [string]$s.repoId }
  $alive = Test-PidAlive $s.pid
  $runnerMatch = $runners | Where-Object {
    ($_.SessionId -and $_.SessionId -eq $s.sessionId) -or ($_.Pid -eq $s.pid)
  } | Select-Object -First 1
  $runnerLabel = if ($alive) { "alive:$($s.pid)" } elseif ($s.pid) { "dead:$($s.pid)" } else { 'none' }
  if ($runnerMatch -and -not $alive) { $runnerLabel = "alive:$($runnerMatch.Pid)" }

  $slice = if ($s.slice -and $s.slice.id) { [string]$s.slice.id } else { '-' }
  $done = 0; $total = 0
  if ($s.counts) {
    $done = [int]($s.counts.done)
    $total = [int]($s.counts.done) + [int]($s.counts.pending) + [int]($s.counts.inProgress) + [int]($s.counts.blocked)
  } elseif ($s.todo) {
    $total = @($s.todo).Count
    $done = @($s.todo | Where-Object { $_.state -eq 'done' }).Count
  }
  $state = if ($alive -or $runnerMatch) { 'ARMED' } elseif ($s.status -eq 'complete') { 'DONE' } else { 'ZOMBIE' }
  $short = Get-RepoShort $primary
  if ($short -eq 'repo' -and $s.repoId) { $short = [string]$s.repoId }
  if ($short -match '^sess_') { $short = Get-RepoShort $primary }

  $row = [pscustomobject]@{
    State     = $state
    Repo      = $short
    Primary   = $primary
    SessionId = $s.sessionId
    Chat      = $s.chatLabel
    Runner    = $runnerLabel
    Slice     = $slice
    Progress  = if ($total -gt 0) { "$done/$total" } else { '-/-' }
    Status    = $s.status
    Title     = $s.ledgerTitle
    Approved  = ''
  }
  $rows.Add($row) | Out-Null
  if ($primary) { $sessionByPrimary[$primary] = $true }
}

# Roots with ledger/flags not already represented
foreach ($root in $roots) {
  $prim = (Resolve-Path -LiteralPath $root -ErrorAction SilentlyContinue)?.Path
  if (-not $prim) { $prim = $root }
  if ($sessionByPrimary.ContainsKey($prim)) { continue }

  $flags = Get-ArmedFlags $prim
  $snap = Get-LedgerSnap $prim
  $runnerMatch = $runners | Where-Object {
    $rd = Get-PrimaryFromPath $_.RepoDir
    $rt = Get-PrimaryFromPath $_.Root
    ($rd -and ($rd -eq $prim)) -or ($rt -and ($rt -eq $prim)) -or
    ($_.RepoDir -like "$prim*") -or ($_.Root -like "$prim*")
  } | Select-Object -First 1

  # Reconcile autopro-session.json: never claim healthy running when PID is dead.
  $sessionFile = Join-Path $prim '.claude\scratch\autopro-session.json'
  $sessObj = $null
  if (Test-Path -LiteralPath $sessionFile) {
    try { $sessObj = Get-Content -LiteralPath $sessionFile -Raw | ConvertFrom-Json } catch { $sessObj = $null }
  }
  $claimedPid = 0
  if ($sessObj -and $sessObj.runnerPid) { try { $claimedPid = [int]$sessObj.runnerPid } catch { $claimedPid = 0 } }
  $claimedAlive = Test-PidAlive $claimedPid
  $claimedHealthy = $sessObj -and ($sessObj.state -match '^(running|armed|booting|finalizing)$')

  $hasFlag = $flags.Count -gt 0
  if (-not $hasFlag -and -not $snap.HasLedger -and -not $runnerMatch -and -not $sessObj) { continue }

  $state = 'IDLE'
  $runnerLabel = 'none'
  $statusLabel = 'idle'
  if ($runnerMatch) {
    $state = 'ARMED'
    $runnerLabel = "alive:$($runnerMatch.Pid)"
    $statusLabel = 'runner-live'
  } elseif ($claimedHealthy -and $claimedAlive) {
    $state = 'ARMED'
    $runnerLabel = "alive:$claimedPid"
    $statusLabel = [string]$sessObj.state
  } elseif ($claimedHealthy -and -not $claimedAlive) {
    # Dead PID still marked running/armed → ZOMBIE (not healthy running)
    $state = 'ZOMBIE'
    $runnerLabel = if ($claimedPid -gt 0) { "dead:$claimedPid" } else { 'dead:unknown' }
    $statusLabel = 'session-stale'
    try {
      $sessObj | Add-Member -NotePropertyName state -NotePropertyValue 'blocked' -Force
      $sessObj | Add-Member -NotePropertyName outcome -NotePropertyValue 'reconcile-dead-runner' -Force
      $sessObj | Add-Member -NotePropertyName updatedAt -NotePropertyValue ((Get-Date).ToString('o')) -Force
      $sessObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $sessionFile -Encoding utf8
    } catch {}
    # Stale kill switch with no process: disarm so launch can re-arm
    if ($hasFlag) {
      $flags | Remove-Item -Force -ErrorAction SilentlyContinue
      $hasFlag = $false
      $statusLabel = 'disarmed-stale'
    }
  } elseif ($hasFlag) {
    $state = 'FLAGGED'
    $runnerLabel = 'none'
    $statusLabel = 'flag-on-no-runner'
  } elseif ($sessObj -and $sessObj.state -eq 'blocked') {
    $state = 'IDLE'
    $statusLabel = "blocked:$($sessObj.outcome)"
  } elseif ($snap.HasLedger) {
    $state = 'IDLE'
    $statusLabel = 'idle'
  }

  $sid = if ($runnerMatch -and $runnerMatch.SessionId) { $runnerMatch.SessionId } elseif ($sessObj -and $sessObj.sessionId) { [string]$sessObj.sessionId } else {
    $flagSess = $flags | Where-Object { $_.Name -match '^autopro-on\.(.+)$' } | Select-Object -First 1
    if ($flagSess -and $flagSess.Name -match '^autopro-on\.(.+)$') { $Matches[1] } else { '-' }
  }

  $rows.Add([pscustomobject]@{
      State     = $state
      Repo      = Get-RepoShort $prim
      Primary   = $prim
      SessionId = $sid
      Chat      = '-'
      Runner    = $runnerLabel
      Slice     = $snap.Slice
      Progress  = if ($snap.Total -gt 0) { "$($snap.Done)/$($snap.Total)" } else { '-/-' }
      Status    = $statusLabel
      Title     = if ($sessObj -and $sessObj.ledgerTitle) { [string]$sessObj.ledgerTitle } else { $snap.Title }
      Approved  = $snap.Approved
    }) | Out-Null
}

# Orphan runners not matched to a row
foreach ($r in $runners) {
  $matched = $rows | Where-Object {
    ($_.SessionId -and $r.SessionId -and $_.SessionId -eq $r.SessionId) -or
    ($_.Runner -eq "alive:$($r.Pid)")
  } | Select-Object -First 1
  if ($matched) { continue }
  $rows.Add([pscustomobject]@{
      State     = 'ARMED'
      Repo      = Get-RepoShort ($r.RepoDir, $r.Root | Where-Object { $_ } | Select-Object -First 1)
      Primary   = Get-PrimaryFromPath ($r.RepoDir)
      SessionId = $r.SessionId
      Chat      = '-'
      Runner    = "alive:$($r.Pid)"
      Slice     = '-'
      Progress  = '-/-'
      Status    = 'runner-only'
      Title     = ''
      Approved  = ''
    }) | Out-Null
}

# Sort: ARMED first, then ZOMBIE, FLAGGED, IDLE
$order = @{ ARMED = 0; ZOMBIE = 1; FLAGGED = 2; DONE = 3; IDLE = 4 }
$sorted = @($rows | Sort-Object { if ($order.ContainsKey($_.State)) { $order[$_.State] } else { 9 } }, Repo)

$summary = "SHOWTIME  board:$($board.Label)  sessions:$($board.Sessions.Count)  runners:$($runners.Count)"

if ($Json) {
  $out = [ordered]@{
    summary  = $summary
    board    = $board
    runners  = $runners
    rows     = $sorted
    at       = (Get-Date).ToUniversalTime().ToString('o')
  }
  $out | ConvertTo-Json -Depth 6
  exit $(if ($board.Ok) { 0 } else { 2 })
}

# Human output
Write-Output $summary
if ($Quiet) {
  exit $(if ($board.Ok) { 0 } else { 2 })
}

if ($sorted.Count -eq 0) {
  Write-Output '  (no armed repos, board sessions, or ledgers found)'
  Write-Output ''
  Write-Output 'Tip: arm with launch-showtime.ps1 -Root <repo> -RepoDir <repo> -AllowDangerousSkipPermissions -IAcceptUnattendedRisk'
  exit $(if ($board.Ok) { 0 } else { 2 })
}

foreach ($row in $sorted) {
  $sess = if ($row.SessionId) { $row.SessionId } else { '-' }
  if ($sess.Length -gt 16 -and $sess -ne '-') { $sess = $sess.Substring(0, 16) }
  $title = if ($row.Title) {
    $t = [string]$row.Title
    if ($t.Length -gt 36) { $t.Substring(0, 35) + '…' } else { $t }
  } else { '' }
  $appr = if ($row.Approved) { "  approved=$($row.Approved)" } else { '' }
  $line = ('{0,-6}  repo={1}  sess={2}  runner:{3}  slice={4}  {5}  status={6}{7}' -f `
      $row.State,
      $row.Repo,
      $sess,
      $row.Runner,
      $row.Slice,
      $row.Progress,
      $row.Status,
      $appr
  )
  if ($title) { $line += "  ledger=$title" }
  Write-Output $line
}

Write-Output ''
Write-Output 'Commands:'
Write-Output '  stop one:   pwsh -File stop-autopro.ps1 -Root <repo>'
Write-Output '  stop all:   pwsh -File stop-autopro.ps1 -All'
Write-Output '  purge dead: board button or POST /api/purge'
Write-Output '  open board: pwsh -File showtime-open-board.ps1 -BoardUrl http://127.0.0.1:8770/'

exit $(if ($board.Ok) { 0 } else { 2 })
