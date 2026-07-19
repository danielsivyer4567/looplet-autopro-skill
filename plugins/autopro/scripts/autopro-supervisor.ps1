<#
  autopro-supervisor.ps1 — detect / kickstart / notify for serial AutoPro.

  Dot-sourced by autopro-runner.ps1. Does not own git. Does not replace the runner loop.
  Responsibilities:
    1. Watchdog: if a worker dies in the first grace window, retry once (kickstart).
    2. Notify: on blocked / needs-you / timeout, write a loud human file + OS toast + board sentinel.
    3. Chat bridge: append structured events to a chat-inbox the arming agent (or human) can poll.

  Paths (repo-local under -ScratchDir, usually <repo>/.claude/scratch):
    AUTOPRO-NEEDS-YOU.md          — human-readable latest alert
    autopro-supervisor-alert.json — machine-readable latest alert
    autopro-chat-inbox.jsonl      — append-only event log for chat bridge

  Global theater bus:
    $HOME/.claude/scratch/autopro-theater/chat-inbox.jsonl
    $HOME/.claude/scratch/autopro-theater/needs-you/<sessionId>.md
#>

#Requires -Version 7.0

function Get-AutoproSupervisorPaths {
  param(
    [Parameter(Mandatory = $true)][string]$ScratchDir,
    [string]$SessionId = ''
  )
  $homeRoot = if ($env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { $HOME }
  $theater = Join-Path $homeRoot '.claude/scratch/autopro-theater'
  $needsYouDir = Join-Path $theater 'needs-you'
  return [pscustomobject]@{
    ScratchDir       = $ScratchDir
    NeedsYouMd       = Join-Path $ScratchDir 'AUTOPRO-NEEDS-YOU.md'
    AlertJson        = Join-Path $ScratchDir 'autopro-supervisor-alert.json'
    ChatInboxJsonl   = Join-Path $ScratchDir 'autopro-chat-inbox.jsonl'
    TheaterRoot      = $theater
    TheaterInboxJsonl = Join-Path $theater 'chat-inbox.jsonl'
    TheaterNeedsYou  = if ($SessionId) { Join-Path $needsYouDir ("{0}.md" -f $SessionId) } else { $null }
    NeedsYouDir      = $needsYouDir
  }
}

function Write-AutoproOsToast {
  param(
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][string]$Body
  )
  # Best-effort. Never throw into the runner loop.
  try {
    if ($IsWindows -or $null -eq $IsWindows) {
      # Prefer BurntToast if installed
      if (Get-Command New-BurntToastNotification -ErrorAction SilentlyContinue) {
        New-BurntToastNotification -Text $Title, $Body -ErrorAction SilentlyContinue | Out-Null
        return 'burnttoast'
      }
      Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
      Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
      $ni = New-Object System.Windows.Forms.NotifyIcon
      $ni.Icon = [System.Drawing.SystemIcons]::Warning
      $ni.Visible = $true
      $ni.BalloonTipTitle = $Title
      $ni.BalloonTipText = if ($Body.Length -gt 220) { $Body.Substring(0, 220) + '…' } else { $Body }
      $ni.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
      $ni.ShowBalloonTip(12000)
      Start-Sleep -Milliseconds 400
      $ni.Dispose()
      return 'notifyicon'
    }
  } catch {}
  try {
    if ($IsMacOS) {
      $safeTitle = $Title -replace '"', "'"
      $safeBody = $Body -replace '"', "'"
      & osascript -e "display notification `"$safeBody`" with title `"$safeTitle`"" 2>$null
      return 'osascript'
    }
  } catch {}
  return 'none'
}

function Send-AutoproSupervisorAlert {
  <#
    Loud human + machine alert. Safe to call from any blocked/timeout path.
    Complete outcomes may set -NeedsHuman:$false (still writes handover pointer).
  #>
  param(
    [Parameter(Mandatory = $true)][string]$ScratchDir,
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][string]$Summary,
    [string]$SessionId = '',
    [string]$RepoDir = '',
    [string]$HandoverPath = '',
    [string]$Detail = '',
    [string]$LogPath = '',
    [hashtable]$Extra = $null,
    [bool]$NeedsHuman = $true
  )

  $paths = Get-AutoproSupervisorPaths -ScratchDir $ScratchDir -SessionId $SessionId
  # Unit tests / temp scratch must not pollute the global theater inbox.
  $scratchNorm = ($ScratchDir -replace '\\', '/').ToLowerInvariant()
  $skipGlobalTheater =
    $scratchNorm -match '/temp/|/tmp/|autopro-sup-|/appdata/local/temp' -or
    $env:AUTOPRO_SUPERVISOR_NO_THEATER -eq '1'
  $ts = (Get-Date).ToString('o')
  $event = [ordered]@{
    schemaVersion = 1
    kind          = $Kind
    summary       = $Summary
    detail        = $Detail
    sessionId     = $SessionId
    repoDir       = $RepoDir
    handoverPath  = $HandoverPath
    logPath       = $LogPath
    at            = $ts
    needsHuman    = [bool]$NeedsHuman
  }
  if ($Extra) {
    foreach ($k in $Extra.Keys) { $event[$k] = $Extra[$k] }
  }

  try {
    if (-not (Test-Path -LiteralPath $ScratchDir)) {
      New-Item -ItemType Directory -Force -Path $ScratchDir | Out-Null
    }
    $event | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $paths.AlertJson -Encoding utf8

    $md = New-Object System.Text.StringBuilder
    $title = if ($NeedsHuman) { '# AUTOPRO NEEDS YOU' } else { '# AUTOPRO COMPLETE — READ HANDOVER' }
    [void]$md.AppendLine($title)
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| | |')
    [void]$md.AppendLine('|--|--|')
    [void]$md.AppendLine("| When | ``$ts`` |")
    [void]$md.AppendLine("| Kind | ``$Kind`` |")
    [void]$md.AppendLine("| Session | ``$SessionId`` |")
    [void]$md.AppendLine("| Repo | ``$RepoDir`` |")
    if ($HandoverPath) { [void]$md.AppendLine("| Handover | ``$HandoverPath`` |") }
    if ($LogPath) { [void]$md.AppendLine("| Log | ``$LogPath`` |") }
    [void]$md.AppendLine('')
    [void]$md.AppendLine('## Summary')
    [void]$md.AppendLine('')
    [void]$md.AppendLine($Summary)
    if ($Detail) {
      [void]$md.AppendLine('')
      [void]$md.AppendLine('## Detail')
      [void]$md.AppendLine('')
      [void]$md.AppendLine('```text')
      [void]$md.AppendLine($Detail)
      [void]$md.AppendLine('```')
    }
    [void]$md.AppendLine('')
    if ($NeedsHuman) {
      [void]$md.AppendLine('## What to do')
      [void]$md.AppendLine('')
      [void]$md.AppendLine('1. Read the handover (if present) and `autopro.log`.')
      [void]$md.AppendLine('2. Fix the blocked slice / env issue, or edit the ledger.')
      [void]$md.AppendLine('3. Re-arm: `launch-showtime.ps1 -Root <repo> -RepoDir <repo> -AllowDangerousSkipPermissions -IAcceptUnattendedRisk`')
      [void]$md.AppendLine('4. Or steer from Show Time ORCH desk (nudge) if the runner is still live.')
    } else {
      [void]$md.AppendLine('## What to do')
      [void]$md.AppendLine('')
      [void]$md.AppendLine('1. Open `SHOWTIME-HANDOVER.md` — full orchestrator report.')
      [void]$md.AppendLine('2. Read the red **STILL TO DO** section (wiring, Supabase, edge, deploy, secrets).')
      [void]$md.AppendLine('3. Ship / deploy only after those items are cleared.')
    }
    [void]$md.AppendLine('')
    [void]$md.AppendLine('**Note:** ORCH on the board is desk/housing only. The **runner** is the conductor; this file is the chat bridge when the arming session is no longer watching.')
    Set-Content -LiteralPath $paths.NeedsYouMd -Value $md.ToString() -Encoding utf8

    $line = ($event | ConvertTo-Json -Depth 8 -Compress)
    Add-Content -LiteralPath $paths.ChatInboxJsonl -Value $line -Encoding utf8

    if (-not $skipGlobalTheater) {
      if (-not (Test-Path -LiteralPath $paths.TheaterRoot)) {
        New-Item -ItemType Directory -Force -Path $paths.TheaterRoot | Out-Null
      }
      Add-Content -LiteralPath $paths.TheaterInboxJsonl -Value $line -Encoding utf8
      if ($paths.TheaterNeedsYou) {
        if (-not (Test-Path -LiteralPath $paths.NeedsYouDir)) {
          New-Item -ItemType Directory -Force -Path $paths.NeedsYouDir | Out-Null
        }
        Set-Content -LiteralPath $paths.TheaterNeedsYou -Value $md.ToString() -Encoding utf8
      }
    }
  } catch {}

  $toast = Write-AutoproOsToast -Title ("AutoPro · {0}" -f $Kind) -Body $Summary
  return [pscustomobject]@{
    NeedsYouMd = $paths.NeedsYouMd
    AlertJson  = $paths.AlertJson
    Toast      = $toast
    At         = $ts
  }
}

function Test-WorkerKickstartAlive {
  param(
    [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
    [int]$GraceSeconds = 12
  )
  if (-not $Process) {
    return [pscustomobject]@{ Alive = $false; EarlyExit = $true; ExitCode = -1; Seconds = 0 }
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $exited = $Process.WaitForExit([Math]::Max(500, $GraceSeconds * 1000))
  $sw.Stop()
  if (-not $exited) {
    return [pscustomobject]@{
      Alive     = $true
      EarlyExit = $false
      ExitCode  = $null
      Seconds   = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
    }
  }
  $code = if ($Process.HasExited) { $Process.ExitCode } else { -1 }
  return [pscustomobject]@{
    Alive     = $false
    EarlyExit = $true
    ExitCode  = $code
    Seconds   = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
  }
}

function Should-KickstartRetry {
  <#
    Pure decision: early death with non-zero exit (or unknown) → retry once.
    Exit 0 inside grace is treated as intentional short success (no retry).
  #>
  param(
    [bool]$EarlyExit,
    $ExitCode,
    [int]$Attempt = 1,
    [int]$MaxAttempts = 2
  )
  if ($Attempt -ge $MaxAttempts) { return $false }
  if (-not $EarlyExit) { return $false }
  if ($null -eq $ExitCode) { return $true }
  if ([int]$ExitCode -eq 0) { return $false }
  return $true
}

function Get-LedgerSliceInventory {
  <#
    Parse ledger.md for slice statuses + out-of-scope / after-done sections.
    Pure string → objects (unit-testable).
  #>
  param([Parameter(Mandatory = $true)][string]$LedgerText)

  $id = '(?:SC-\d+|SD-[\w-]+|H\d+|P\d+[-\w]*)'
  $slices = [System.Collections.Generic.List[object]]::new()
  foreach ($m in [regex]::Matches($LedgerText, "(?m)^##\s+($id)\s+(?:[—–-]\s*)?(.+?)\s+\[(pending|in-progress|done|blocked)\]\s*$")) {
    [void]$slices.Add([pscustomobject]@{
        Id     = $m.Groups[1].Value.Trim()
        Title  = $m.Groups[2].Value.Trim()
        Status = $m.Groups[3].Value.Trim().ToLowerInvariant()
      })
  }

  $outOfScope = @()
  $mOut = [regex]::Match(
    $LedgerText,
    '(?is)##\s*Out of scope[^\n]*\r?\n(.*?)(?=\r?\n##\s|\z)'
  )
  if ($mOut.Success) {
    $outOfScope = @(
      $mOut.Groups[1].Value -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^\s*[-*]' -or $_ -match '^\s*\d+\.' }
    )
  }

  $afterDone = @()
  $mAfter = [regex]::Match(
    $LedgerText,
    '(?is)##\s*After\s+100%[^\n]*\r?\n(.*?)(?=\r?\n##\s|\z)'
  )
  if ($mAfter.Success) {
    $afterDone = @(
      $mAfter.Groups[1].Value -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^\s*[-*\d]' }
    )
  }

  return [pscustomobject]@{
    Slices     = @($slices)
    Pending    = @($slices | Where-Object { $_.Status -eq 'pending' })
    InProgress = @($slices | Where-Object { $_.Status -eq 'in-progress' })
    Blocked    = @($slices | Where-Object { $_.Status -eq 'blocked' })
    Done       = @($slices | Where-Object { $_.Status -eq 'done' })
    OutOfScope = $outOfScope
    AfterDone  = $afterDone
  }
}

function Get-WiringStillTodoHints {
  <#
    Scan ledger + notes for wiring / platform / ops leftovers (Supabase, edge,
    env, deploy, CORS, secrets, etc.). Returns unique bullet strings.
  #>
  param(
    [string]$LedgerText = '',
    [string]$Notes = '',
    [string[]]$ExtraLines = @()
  )
  $blob = @($LedgerText, $Notes) + @($ExtraLines) -join "`n"
  if (-not $blob.Trim()) { return @() }

  $patterns = @(
    @{ Re = '(?i)supabase'; Label = 'Supabase (schema / RLS / keys / dashboard wiring)' }
    @{ Re = '(?i)edge\s*function|deno\.deploy|workers\.dev'; Label = 'Edge functions / Workers deploy + secrets' }
    @{ Re = '(?i)cloudflare|wrangler'; Label = 'Cloudflare / wrangler deploy + bindings' }
    @{ Re = '(?i)\.env|API[_ ]?KEY|secret|MINIMAX|OPENAI|ANTHROPIC'; Label = 'Env / API keys / secrets on target host' }
    @{ Re = '(?i)\bCORS\b|enable-cors|origin'; Label = 'CORS / origin allowlist (Engine, APIs)' }
    @{ Re = '(?i)migrat|drizzle|prisma|sql'; Label = 'DB migrations / schema apply' }
    @{ Re = '(?i)webhook|stripe|billing'; Label = 'Webhooks / billing provider wiring' }
    @{ Re = '(?i)oauth|auth\s*redirect|callback'; Label = 'Auth / OAuth redirect URLs' }
    @{ Re = '(?i)dns|domain|ssl|cert'; Label = 'DNS / TLS / custom domain' }
    @{ Re = '(?i)ci/cd|github\s*actions|pipeline'; Label = 'CI/CD pipeline green on default branch' }
    @{ Re = '(?i)deploy|production|prod\b|staging'; Label = 'Production / staging deploy of this tip' }
    @{ Re = '(?i)comfy|engine\s*pin|8188'; Label = 'Looplet Engine pin install on target machine' }
    @{ Re = '(?i)ace-?step|7867'; Label = 'ACE-Step local music server + probe/approve' }
    @{ Re = '(?i)playwright|e2e|release-proof'; Label = 'Release-proof / e2e against target env' }
    @{ Re = '(?i)PR\b|pull request|merge|ship-epic'; Label = 'PR / merge / ship-epic to mainline' }
  )

  $found = [System.Collections.Generic.List[string]]::new()
  $seen = @{}
  foreach ($p in $patterns) {
    if ($blob -match $p.Re) {
      $lab = [string]$p.Label
      if (-not $seen.ContainsKey($lab)) {
        $seen[$lab] = $true
        [void]$found.Add($lab)
      }
    }
  }
  return @($found)
}

function Format-StillTodoRedHtml {
  <#
    Red "STILL TO DO" block for handover markdown (HTML renders red in most previews).
  #>
  param(
    [string[]]$Items = @(),
    [string]$Outcome = ''
  )
  $lines = [System.Collections.Generic.List[string]]::new()
  [void]$lines.Add('')
  [void]$lines.Add('<div style="color:#c62828;border:2px solid #c62828;padding:12px 16px;margin:20px 0;border-radius:8px;background:#fff5f5">')
  [void]$lines.Add('')
  [void]$lines.Add('<h2 style="color:#b71c1c;margin-top:0">⛔ STILL TO DO</h2>')
  [void]$lines.Add('')
  [void]$lines.Add('<p style="color:#c62828;font-weight:600">Not done by AutoPro — human / next epic must finish these before calling the product fully wired.</p>')
  [void]$lines.Add('')
  if (-not $Items -or $Items.Count -eq 0) {
    if ($Outcome -eq 'complete') {
      [void]$lines.Add('<p style="color:#c62828">No incomplete ledger slices detected. Still verify production wiring, secrets, and deploy yourself — AutoPro does not ship to prod.</p>')
    } else {
      [void]$lines.Add('<p style="color:#c62828">Outcome was not clean complete — resolve the Summary / Final Check sections above, then re-arm.</p>')
    }
  } else {
    [void]$lines.Add('<ul style="color:#c62828">')
    foreach ($item in $Items) {
      $safe = ([string]$item) -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
      [void]$lines.Add(("  <li>{0}</li>" -f $safe))
    }
    [void]$lines.Add('</ul>')
  }
  [void]$lines.Add('')
  [void]$lines.Add('</div>')
  [void]$lines.Add('')
  return ($lines -join "`n")
}
