#Requires -Version 7.0
<#
  autopro-watch.ps1 — poll the chat bridge so the human (or arming agent) is never
  out of the loop after -autopro arms and the arming chat stops.

  Watches (in priority order):
    1) <Root>/.claude/scratch/autopro-chat-inbox.jsonl   — structured events
    2) <Root>/.claude/scratch/AUTOPRO-NEEDS-YOU.md       — latest loud alert
    3) <Root>/.claude/scratch/autopro.log                — optional -AlsoLog tail
    4) global ~/.claude/scratch/autopro-theater/chat-inbox.jsonl

  Prints every new inbox line to stdout (agent-friendly). On NeedsHuman alerts,
  also re-fires an OS toast (best-effort) if the file is newer than last seen.

  Usage:
    pwsh -NoProfile -File autopro-watch.ps1 -Root C:\repos\looplet-producer
    pwsh -NoProfile -File autopro-watch.ps1 -Root <repo> -Once    # single poll, exit
    pwsh -NoProfile -File autopro-watch.ps1 -Root <repo> -AlsoLog

  Exit codes:
    0  idle / watching (or -Once with no needs-you)
    2  -Once and latest alert NeedsHuman=true
    3  no scratch dir / invalid root
#>
param(
  [Parameter(Mandatory = $true)][string]$Root,
  [int]$PollSeconds = 2,
  [switch]$Once,
  [switch]$AlsoLog,
  [switch]$Quiet,
  # When set, stop watching when autopro-on* flags disappear (run complete/stopped)
  [switch]$UntilDisarmed
)

$ErrorActionPreference = 'Stop'
$scratch = Join-Path $Root '.claude/scratch'
if (-not (Test-Path -LiteralPath $scratch)) {
  Write-Error "No scratch at $scratch — pass -Root to the repo that was armed."
  exit 3
}

. (Join-Path $PSScriptRoot 'autopro-supervisor.ps1')

$inbox = Join-Path $scratch 'autopro-chat-inbox.jsonl'
$needsYou = Join-Path $scratch 'AUTOPRO-NEEDS-YOU.md'
$alertJson = Join-Path $scratch 'autopro-supervisor-alert.json'
$logPath = Join-Path $scratch 'autopro.log'
$homeRoot = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { $HOME }
$theaterInbox = Join-Path $homeRoot '.claude/scratch/autopro-theater/chat-inbox.jsonl'

function Get-FileOffset([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return 0L }
  try { return [int64](Get-Item -LiteralPath $Path).Length } catch { return 0L }
}

function Read-NewLines([string]$Path, [ref]$Offset) {
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  try {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
      if ($Offset.Value -gt $fs.Length) { $Offset.Value = 0L }
      $fs.Seek($Offset.Value, [IO.SeekOrigin]::Begin) | Out-Null
      $sr = [IO.StreamReader]::new($fs, [Text.Encoding]::UTF8, $true, 4096, $true)
      try {
        $chunk = $sr.ReadToEnd()
        $Offset.Value = $fs.Position
      } finally { $sr.Dispose() }
    } finally { $fs.Dispose() }
    if (-not $chunk) { return @() }
    return @($chunk -split "`r?`n" | Where-Object { $_ -ne '' })
  } catch {
    return @()
  }
}

function Test-Armed {
  $flags = @(Get-ChildItem -Path (Join-Path $scratch 'autopro-on*') -File -ErrorAction SilentlyContinue)
  return ($flags.Count -gt 0)
}

function Write-Banner([string]$Text, [string]$Color = 'Cyan') {
  if ($Quiet) { return }
  Write-Host ''
  Write-Host ('═' * 60) -ForegroundColor $Color
  Write-Host $Text -ForegroundColor $Color
  Write-Host ('═' * 60) -ForegroundColor $Color
}

$offInbox = Get-FileOffset $inbox
$offTheater = Get-FileOffset $theaterInbox
$offLog = if ($AlsoLog) { Get-FileOffset $logPath } else { 0L }
# Continuous mode starts at EOF (only new events). -Once uses repo-local
# alert/needs-you + last repo inbox lines — never the global theater history
# (unit tests and other repos pollute chat-inbox.jsonl).
if ($Once) {
  $offTheater = Get-FileOffset $theaterInbox # do not replay global history
  # Repo inbox: last ~8KB only
  $sz = Get-FileOffset $inbox
  $offInbox = [Math]::Max(0L, $sz - 8192L)
}

$lastNeedsMtime = $null
$exitNeedsHuman = $false
$started = Get-Date

if (-not $Quiet) {
  Write-Banner 'AUTOPRO WATCH · chat bridge' 'Green'
  Write-Host ("Root     : {0}" -f $Root)
  Write-Host ("Inbox    : {0}" -f $inbox)
  Write-Host ("Needs-you: {0}" -f $needsYou)
  Write-Host ("Armed    : {0}" -f $(if (Test-Armed) { 'yes' } else { 'no (waiting/flags cleared)' }))
  Write-Host ("Poll     : {0}s  Once={1} AlsoLog={2}" -f $PollSeconds, [bool]$Once, [bool]$AlsoLog)
  Write-Host ''
  Write-Host 'Waiting for supervisor events (blocked / kickstart / complete)…' -ForegroundColor DarkGray
}

function Emit-InboxLine([string]$Line, [string]$Source) {
  $kind = ''
  $summary = ''
  $needs = $false
  try {
    $j = $Line | ConvertFrom-Json -ErrorAction Stop
    if ($j.kind) { $kind = [string]$j.kind }
    if ($j.summary) { $summary = [string]$j.summary }
    if ($null -ne $j.needsHuman) { $needs = [bool]$j.needsHuman }
    elseif ($kind -and $kind -notmatch 'complete|info|progress') { $needs = $true }
  } catch {
    Write-Host ("[{0}] {1}" -f $Source, $Line)
    return $false
  }
  $ts = try { [string]$j.at } catch { (Get-Date).ToString('o') }
  $color = if ($needs) { 'Red' } elseif ($kind -match 'complete') { 'Green' } else { 'Yellow' }
  $tag = if ($needs) { 'NEEDS YOU' } elseif ($kind -match 'complete') { 'COMPLETE' } else { 'EVENT' }
  Write-Host ''
  Write-Host ("── {0} · {1} · {2} ──" -f $tag, $kind, $ts) -ForegroundColor $color
  if ($summary) { Write-Host $summary -ForegroundColor $color }
  if ($j.sessionId) { Write-Host ("session  : {0}" -f $j.sessionId) }
  if ($j.handoverPath) { Write-Host ("handover : {0}" -f $j.handoverPath) }
  if ($j.detail) {
    $d = [string]$j.detail
    if ($d.Length -gt 400) { $d = $d.Substring(0, 400) + '…' }
    Write-Host $d -ForegroundColor DarkGray
  }
  Write-Host ("raw      : {0}" -f $Line) -ForegroundColor DarkGray
  return $needs
}

function Maybe-ToastNeedsYou {
  if (-not (Test-Path -LiteralPath $needsYou)) { return }
  try {
    $item = Get-Item -LiteralPath $needsYou
    if ($script:lastNeedsMtime -and $item.LastWriteTimeUtc -le $script:lastNeedsMtime) { return }
    $script:lastNeedsMtime = $item.LastWriteTimeUtc
    $body = Get-Content -LiteralPath $needsYou -Raw -ErrorAction SilentlyContinue
    if (-not $body) { return }
    if ($body -match 'AUTOPRO COMPLETE') { return } # complete is not a needs-you toast spam
    $summary = if ($body -match '(?m)^## Summary\s*\r?\n(.+)') { $Matches[1].Trim() }
               elseif ($body -match '(?m)^Summary:\s*(.+)$') { $Matches[1].Trim() }
               else { 'AutoPro needs you — open AUTOPRO-NEEDS-YOU.md' }
    if ($summary.Length -gt 180) { $summary = $summary.Substring(0, 180) + '…' }
    $null = Write-AutoproOsToast -Title 'AutoPro NEEDS YOU' -Body $summary
    if (-not $Quiet) {
      Write-Host ''
      Write-Host '═══ AUTOPRO-NEEDS-YOU.md ═══' -ForegroundColor Red
      Write-Host ($body.Substring(0, [Math]::Min(1200, $body.Length))) -ForegroundColor Red
      if ($body.Length -gt 1200) { Write-Host '…' -ForegroundColor DarkRed }
    }
  } catch {}
}

function Poll-Once {
  $needs = $false
  foreach ($line in (Read-NewLines $inbox ([ref]$offInbox))) {
    # Prefer events for this root when repoDir is present
    $forThis = $true
    try {
      $j = $line | ConvertFrom-Json -ErrorAction Stop
      if ($j.repoDir -and $Root) {
        $rd = [string]$j.repoDir
        $forThis = ($rd -ieq $Root) -or ($rd -like ($Root.TrimEnd('\','/') + '*'))
      }
    } catch { $forThis = $true }
    if (-not $forThis) { continue }
    if (Emit-InboxLine $line 'repo-inbox') { $needs = $true }
  }
  # Continuous only: global theater (filtered by repo when possible)
  if (-not $script:OnceMode) {
    foreach ($line in (Read-NewLines $theaterInbox ([ref]$offTheater))) {
      $forThis = $true
      try {
        $j = $line | ConvertFrom-Json -ErrorAction Stop
        if ($j.repoDir -and $Root) {
          $rd = [string]$j.repoDir
          $forThis = ($rd -ieq $Root) -or ($rd -like ($Root.TrimEnd('\','/') + '*'))
        }
      } catch { $forThis = $true }
      if (-not $forThis) { continue }
      if (Emit-InboxLine $line 'theater-inbox') { $needs = $true }
    }
  }
  if ($AlsoLog) {
    foreach ($line in (Read-NewLines $logPath ([ref]$offLog))) {
      if ($line -match 'SUPERVISOR_ALERT|KICKSTART_FAILED|NEEDS YOU|FINAL_CHECK|blocked|handover') {
        Write-Host ("[log] {0}" -f $line) -ForegroundColor Magenta
      }
    }
  }
  Maybe-ToastNeedsYou
  if (Test-Path -LiteralPath $alertJson) {
    try {
      $a = Get-Content -LiteralPath $alertJson -Raw | ConvertFrom-Json
      if ($a.needsHuman -eq $true) { $needs = $true }
      # Stale unit-test / complete markers: only trust if recent (< 2h) or armed
      if ($needs -and $a.at) {
        try {
          $age = ([DateTime]::Now - [DateTime]::Parse([string]$a.at)).TotalHours
          if ($age -gt 2 -and -not (Test-Armed)) { $needs = $false }
        } catch {}
      }
    } catch {}
  }
  # Needs-you file without armed run and with COMPLETE title → not needs-human
  if ($needs -and (Test-Path -LiteralPath $needsYou)) {
    try {
      $body = Get-Content -LiteralPath $needsYou -Raw
      if ($body -match 'AUTOPRO COMPLETE' -and $body -notmatch 'NEEDS YOU') { $needs = $false }
    } catch {}
  }
  return $needs
}
$script:OnceMode = [bool]$Once

if ($Once) {
  # For once-mode, show last few inbox lines
  $exitNeedsHuman = [bool](Poll-Once)
  if (-not $Quiet) {
    if ($exitNeedsHuman) {
      Write-Host ''
      Write-Host 'WATCH_ONCE=needs-human' -ForegroundColor Red
    } else {
      Write-Host 'WATCH_ONCE=idle' -ForegroundColor DarkGray
    }
  }
  exit $(if ($exitNeedsHuman) { 2 } else { 0 })
}

while ($true) {
  $hit = Poll-Once
  if ($hit) { $exitNeedsHuman = $true }
  if ($UntilDisarmed -and -not (Test-Armed)) {
    if (-not $Quiet) {
      Write-Banner 'Flags cleared — watch stopping (disarmed / complete)' 'Green'
    }
    break
  }
  Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
}

exit $(if ($exitNeedsHuman) { 2 } else { 0 })
