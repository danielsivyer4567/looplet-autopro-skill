<#
  showtime-status.ps1 — ongoing operator log (NOT for git).

  Writes/updates:
    <RepoDir>/.claude/scratch/SHOWTIME-STATUS.md

  Sections always rebuilt from ledger + session events:
    - Done
    - In progress / live
    - Blockers
    - Server / env requirements
    - Session history (append-only event log)

  Usage:
    pwsh -File showtime-status.ps1 -RepoDir <repo> -Action refresh
    pwsh -File showtime-status.ps1 -RepoDir <repo> -Action event -Event "..." -Level done|block|server|info
#>
param(
  [Parameter(Mandatory = $true)][string]$RepoDir,
  [ValidateSet('refresh', 'event', 'init')]
  [string]$Action = 'refresh',
  [string]$SessionId = '',
  [string]$Event = '',
  [ValidateSet('done', 'block', 'server', 'info', 'finish')]
  [string]$Level = 'info',
  [string]$LedgerPath = '',
  [string]$MergeTarget = '',
  [string]$WorktreeDir = '',
  [string]$Commit = ''
)

$ErrorActionPreference = 'Stop'
$scratch = Join-Path $RepoDir '.claude\scratch'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$statusPath = Join-Path $scratch 'SHOWTIME-STATUS.md'
$eventsPath = Join-Path $scratch 'SHOWTIME-STATUS.events.jsonl'
if (-not $LedgerPath) { $LedgerPath = Join-Path $scratch 'ledger.md' }

function Get-LedgerFacts([string]$path) {
  $done = @(); $pending = @(); $inprog = @(); $blocked = @()
  $title = 'ledger'
  $approved = 'unknown'
  if (-not (Test-Path -LiteralPath $path)) {
    return [pscustomobject]@{ Title = $title; Approved = $approved; Done = $done; Pending = $pending; InProgress = $inprog; Blocked = $blocked }
  }
  $raw = Get-Content -LiteralPath $path -Raw
  $tm = [regex]::Match($raw, '(?m)^#\s+Ledger:\s*(.+)$')
  if ($tm.Success) { $title = $tm.Groups[1].Value.Trim() }
  $am = [regex]::Match($raw, '(?im)^Approved:\s*(.+)$')
  if ($am.Success) { $approved = $am.Groups[1].Value.Trim() }

  $re = [regex]'(?m)^##\s+(SC-\d+|SD-[\w-]+|H\d+|P\d+[-\w]*)\s+(?:[—–-]\s+)?(.+?)\s+\[(pending|in-progress|done|blocked)\]'
  foreach ($m in $re.Matches($raw)) {
    $item = [pscustomobject]@{ Id = $m.Groups[1].Value; Title = $m.Groups[2].Value.Trim(); State = $m.Groups[3].Value.ToLowerInvariant() }
    switch ($item.State) {
      'done' { $done += $item }
      'pending' { $pending += $item }
      'in-progress' { $inprog += $item }
      'blocked' { $blocked += $item }
    }
  }
  return [pscustomobject]@{
    Title = $title; Approved = $approved
    Done = $done; Pending = $pending; InProgress = $inprog; Blocked = $blocked
  }
}

function Add-Event([string]$level, [string]$text, [string]$sessionId) {
  $line = (@{
    at = (Get-Date).ToUniversalTime().ToString('o')
    level = $level
    sessionId = $sessionId
    text = $text
  } | ConvertTo-Json -Compress)
  Add-Content -LiteralPath $eventsPath -Value $line -Encoding utf8
}

function Get-RecentEvents([int]$n = 40) {
  if (-not (Test-Path -LiteralPath $eventsPath)) { return @() }
  $lines = @(Get-Content -LiteralPath $eventsPath -ErrorAction SilentlyContinue)
  if (-not $lines) { return @() }
  $take = [Math]::Min($n, $lines.Count)
  return $lines[($lines.Count - $take)..($lines.Count - 1)]
}

function Write-StatusFile {
  $facts = Get-LedgerFacts $LedgerPath
  $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('# SHOWTIME STATUS (local only — not in git)')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine("> Living operator log so nothing is missed. Path: ``.claude/scratch/SHOWTIME-STATUS.md``")
  [void]$sb.AppendLine("> Updated: **$now**")
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine("## Ledger")
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine("| | |")
  [void]$sb.AppendLine("|--|--|")
  [void]$sb.AppendLine("| **Title** | $($facts.Title) |")
  [void]$sb.AppendLine("| **Approved** | $($facts.Approved) |")
  [void]$sb.AppendLine("| **Done** | $($facts.Done.Count) |")
  [void]$sb.AppendLine("| **In progress** | $($facts.InProgress.Count) |")
  [void]$sb.AppendLine("| **Pending** | $($facts.Pending.Count) |")
  [void]$sb.AppendLine("| **Blocked** | $($facts.Blocked.Count) |")
  if ($SessionId) { [void]$sb.AppendLine("| **Last session** | ``$SessionId`` |") }
  if ($MergeTarget) { [void]$sb.AppendLine("| **Merge target** | ``$MergeTarget`` |") }
  if ($WorktreeDir) { [void]$sb.AppendLine("| **Worktree** | ``$WorktreeDir`` |") }
  if ($Commit) { [void]$sb.AppendLine("| **Last commit** | ``$Commit`` |") }
  [void]$sb.AppendLine('')

  [void]$sb.AppendLine('## Done (do not re-open)')
  [void]$sb.AppendLine('')
  if ($facts.Done.Count -eq 0) { [void]$sb.AppendLine('_None yet._') }
  else {
    foreach ($d in $facts.Done) {
      [void]$sb.AppendLine("- [x] **$($d.Id)** — $($d.Title)")
    }
  }
  [void]$sb.AppendLine('')

  [void]$sb.AppendLine('## In progress / live')
  [void]$sb.AppendLine('')
  if ($facts.InProgress.Count -eq 0) { [void]$sb.AppendLine('_Nothing in progress._') }
  else {
    foreach ($d in $facts.InProgress) {
      [void]$sb.AppendLine("- [ ] **$($d.Id)** — $($d.Title)")
    }
  }
  [void]$sb.AppendLine('')

  [void]$sb.AppendLine('## Pending')
  [void]$sb.AppendLine('')
  if ($facts.Pending.Count -eq 0) { [void]$sb.AppendLine('_Queue empty._') }
  else {
    foreach ($d in $facts.Pending) {
      [void]$sb.AppendLine("- [ ] **$($d.Id)** — $($d.Title)")
    }
  }
  [void]$sb.AppendLine('')

  [void]$sb.AppendLine('## Current blockers')
  [void]$sb.AppendLine('')
  if ($facts.Blocked.Count -eq 0) { [void]$sb.AppendLine('_No ledger-blocked slices._') }
  else {
    foreach ($d in $facts.Blocked) {
      [void]$sb.AppendLine("- [ ] **BLOCKED $($d.Id)** — $($d.Title)")
    }
  }
  # Also surface recent block events
  $blockEvents = Get-RecentEvents 80 | ForEach-Object {
    try { $_ | ConvertFrom-Json } catch { $null }
  } | Where-Object { $_ -and $_.level -eq 'block' }
  if ($blockEvents) {
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Recent block events')
    [void]$sb.AppendLine('')
    foreach ($e in ($blockEvents | Select-Object -Last 15)) {
      [void]$sb.AppendLine("- $($e.at) · ``$($e.sessionId)`` — $($e.text)")
    }
  }
  [void]$sb.AppendLine('')

  [void]$sb.AppendLine('## Server / env requirements (do not drop)')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('Track anything that needs a running service, secret, migration, or deploy:')
  [void]$sb.AppendLine('')
  $serverEvents = Get-RecentEvents 120 | ForEach-Object {
    try { $_ | ConvertFrom-Json } catch { $null }
  } | Where-Object { $_ -and $_.level -eq 'server' }
  if (-not $serverEvents -or $serverEvents.Count -eq 0) {
    [void]$sb.AppendLine('- _(none logged yet — append with `-Action event -Level server`)_')
    # Prefer live port from server.port; avoid a second hard-coded URL that drifts from the TV card.
    $boardHint = 'Show Time board: (start via launch-showtime / theater-server — URL on TV card + SHOWTIME_URL)'
    $portFile = Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater\server.port'
    if (Test-Path -LiteralPath $portFile) {
      $p = (Get-Content -LiteralPath $portFile -Raw).Trim()
      if ($p -match '^\d+$') { $boardHint = "Show Time board: ``http://127.0.0.1:$p/``" }
    }
    [void]$sb.AppendLine("- $boardHint")
    [void]$sb.AppendLine('- Autopro log: `.claude/scratch/autopro.log`')
  } else {
    foreach ($e in ($serverEvents | Select-Object -Last 30)) {
      [void]$sb.AppendLine("- $($e.at) · $($e.text)")
    }
  }
  [void]$sb.AppendLine('')

  [void]$sb.AppendLine('## Session / finish history')
  [void]$sb.AppendLine('')
  $all = Get-RecentEvents 50 | ForEach-Object {
    try { $_ | ConvertFrom-Json } catch { $null }
  } | Where-Object { $_ }
  if (-not $all) { [void]$sb.AppendLine('_No events yet._') }
  else {
    foreach ($e in $all) {
      [void]$sb.AppendLine("- **$($e.level)** $($e.at) ``$($e.sessionId)`` — $($e.text)")
    }
  }
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('---')
  [void]$sb.AppendLine('_This file is local operator memory. Keep it out of git._')

  Set-Content -LiteralPath $statusPath -Value $sb.ToString() -Encoding utf8
  Write-Output "STATUS_PATH=$statusPath"
}

switch ($Action) {
  'init' {
    Add-Event 'info' 'SHOWTIME-STATUS initialized' $SessionId
    Write-StatusFile
  }
  'event' {
    if (-not $Event) { throw 'Event text required' }
    Add-Event $Level $Event $SessionId
    Write-StatusFile
  }
  'refresh' {
    Write-StatusFile
  }
}
