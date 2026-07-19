# join-alarm-loud.ps1 — ONE short WAV + bottom-right Approve/Deny popup.
# Payload: %USERPROFILE%\.claude\scratch\autopro-theater\join-alarm-payload.json
# Posts approve/deny to local theater with server.token — no board navigation required.
#
# Scope rule: WinForms Click handlers run in a weird runspace — ALL mutable
# state lives in $script: and is re-read from disk on every click (token/port).
$ErrorActionPreference = 'Continue'
$script:state = Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater'
$script:log = Join-Path $script:state 'join-alarm.log'
$script:payloadPath = Join-Path $script:state 'join-alarm-payload.json'

function Log([string]$m) {
  try { Add-Content -LiteralPath $script:log -Value ((Get-Date -Format o) + ' ' + $m) -Encoding utf8 } catch {}
}
Log 'join-alarm start (once + action popup)'

$script:title = 'SHOW TIME — JOIN REQUEST'
$script:body = 'Approve or deny this fleet'
$script:joinId = ''
$script:repoId = ''
$script:branch = ''
$script:ledgerTitle = ''
$script:repoPath = ''
$script:sessionId = ''
$script:boardUrl = 'http://127.0.0.1:8770/'
$script:port = '8770'

try {
  if (Test-Path -LiteralPath $script:payloadPath) {
    $j = Get-Content -LiteralPath $script:payloadPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($j.title) { $script:title = [string]$j.title }
    if ($j.body) { $script:body = [string]$j.body }
    if ($j.joinId) { $script:joinId = [string]$j.joinId }
    if ($j.repoId) { $script:repoId = [string]$j.repoId }
    if ($j.branch) { $script:branch = [string]$j.branch }
    if ($j.ledgerTitle) { $script:ledgerTitle = [string]$j.ledgerTitle }
    if ($j.repoPath) { $script:repoPath = [string]$j.repoPath }
    if ($j.sessionId) { $script:sessionId = [string]$j.sessionId }
    if ($j.boardUrl) { $script:boardUrl = [string]$j.boardUrl }
    if ($j.port) { $script:port = [string]$j.port }
  }
} catch { Log ('payload fail: ' + $_) }

function Read-ShowTimeToken {
  try {
    $tf = Join-Path $script:state 'server.token'
    if (Test-Path -LiteralPath $tf) {
      $t = (Get-Content -LiteralPath $tf -Raw -Encoding utf8).Trim()
      # strip BOM / whitespace
      $t = $t -replace '^\uFEFF', ''
      if ($t -match '^[a-fA-F0-9]{16,}$') { return $t }
      return $t
    }
  } catch {}
  return ''
}
function Read-ShowTimePort {
  try {
    $pf = Join-Path $script:state 'server.port'
    if (Test-Path -LiteralPath $pf) {
      $p = (Get-Content -LiteralPath $pf -Raw).Trim()
      if ($p -match '^\d+$') { return $p }
    }
  } catch {}
  if ($script:port -match '^\d+$') { return $script:port }
  return '8770'
}

if (-not $script:port -or $script:port -notmatch '^\d+$') {
  $script:port = Read-ShowTimePort
}
if ($script:boardUrl -notmatch '://') {
  $script:boardUrl = "http://127.0.0.1:$($script:port)/"
}

# --- sound once: operator join chime (theater/assets/join-chime.wav) ---
# MUST PlaySync (or Play + hold the player until duration elapses).
# Fire-and-forget Play() returns immediately; the SoundPlayer is then GC'd /
# process moves on and the voice gets cut off mid-line (seen 2026-07-19 with
# shake-and-bake ~3.2s clip).
function Resolve-JoinChimeWav {
  $skillAssets = Join-Path $env:USERPROFILE '.claude\skills\autopro\theater\assets'
  $candidates = @(
    (Join-Path $script:state 'join-chime.wav'),
    (Join-Path $skillAssets 'join-chime.wav'),
    (Join-Path $skillAssets 'shake-and-bake-motherfucker--i.wav'),
    (Join-Path (Split-Path -Parent $PSCommandPath) 'join-chime.wav'),
    (Join-Path $env:USERPROFILE '.agents\skills\autopro\theater\assets\join-chime.wav')
  )
  foreach ($p in $candidates) {
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}

function Get-WavDurationMs {
  param([Parameter(Mandatory = $true)][string]$Path)
  try {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 44) { return 4000 }
    $sr = [BitConverter]::ToInt32($bytes, 24)
    $ch = [BitConverter]::ToInt16($bytes, 22)
    $bits = [BitConverter]::ToInt16($bytes, 34)
    $dataSize = 0
    for ($i = 12; $i -lt [Math]::Min($bytes.Length - 8, 512); $i++) {
      if ($bytes[$i] -eq 0x64 -and $bytes[$i + 1] -eq 0x61 -and $bytes[$i + 2] -eq 0x74 -and $bytes[$i + 3] -eq 0x61) {
        $dataSize = [BitConverter]::ToInt32($bytes, $i + 4)
        break
      }
    }
    if ($dataSize -le 0) { $dataSize = [Math]::Max(0, $bytes.Length - 44) }
    $bps = $sr * $ch * [Math]::Max(1, $bits / 8)
    if ($bps -le 0) { return 4000 }
    $ms = [int][Math]::Ceiling(1000.0 * $dataSize / $bps) + 250  # pad for codec tail
    return [Math]::Max(500, [Math]::Min($ms, 60000))
  } catch {
    return 4000
  }
}

function Play-JoinChime {
  $wav = Resolve-JoinChimeWav
  if (-not $wav) { return $false }
  try {
    $ms = Get-WavDurationMs -Path $wav
    Log ("play-full join-chime path={0} durationMs={1}" -f $wav, $ms)
    # Keep player in script scope so it cannot be GC'd mid-playback.
    $script:JoinChimePlayer = New-Object System.Media.SoundPlayer $wav
    $script:JoinChimePlayer.Load()
    # PlaySync blocks until the WHOLE clip finishes — no cut-off.
    $script:JoinChimePlayer.PlaySync()
    Log 'play-full join-chime complete'
    return $true
  } catch {
    Log ('join chime fail: ' + $_)
    # Fallback: async play + sleep for measured duration
    try {
      $wav2 = Resolve-JoinChimeWav
      if (-not $wav2) { return $false }
      $ms2 = Get-WavDurationMs -Path $wav2
      $script:JoinChimePlayer = New-Object System.Media.SoundPlayer $wav2
      $script:JoinChimePlayer.Load()
      $script:JoinChimePlayer.Play()
      Start-Sleep -Milliseconds $ms2
      try { $script:JoinChimePlayer.Stop() } catch {}
      Log ("play-async+wait join-chime complete ms={0}" -f $ms2)
      return $true
    } catch {
      Log ('join chime fallback fail: ' + $_)
      return $false
    }
  }
}

if (-not (Play-JoinChime)) {
  $media = Join-Path $env:WINDIR 'Media'
  $names = @('Ring01.wav', 'Windows Notify.wav', 'Alarm01.wav', 'Alarm02.wav')
  $wav = $null
  foreach ($n in $names) {
    $p = Join-Path $media $n
    if (Test-Path -LiteralPath $p) { $wav = $p; break }
  }
  if ($wav) {
    try {
      $script:JoinChimePlayer = New-Object System.Media.SoundPlayer $wav
      $script:JoinChimePlayer.Load()
      $script:JoinChimePlayer.PlaySync()
      Log ('play-full fallback ' + $wav)
    } catch { Log ('play fail: ' + $_) }
  } else {
    Log 'NO WAV FILES'
  }
}

# --- HTTP (no Invoke-RestMethod quirks; full 401 body) ---
function Invoke-JoinAct([string]$act) {
  if (-not $script:joinId) { throw 'missing joinId in payload' }
  $liveToken = Read-ShowTimeToken
  $livePort = Read-ShowTimePort
  if (-not $liveToken) { throw 'missing server.token — open http://127.0.0.1:8770/ once then retry' }

  $uri = "http://127.0.0.1:$livePort/api/join-requests/$([uri]::EscapeDataString($script:joinId))/$act"
  $bodyObj = if ($act -eq 'deny') {
    @{ by = 'os-toast'; reason = 'denied from join popup' }
  } else {
    @{ by = 'os-toast' }
  }
  $json = $bodyObj | ConvertTo-Json -Compress
  Log ("POST $act joinId=$($script:joinId) port=$livePort tokenLen=$($liveToken.Length) uri=$uri")

  $attempt = 0
  $lastErr = $null
  while ($attempt -lt 2) {
    $attempt++
    try {
      # WebRequest so we control headers + read error JSON body on 401
      $resp = Invoke-WebRequest -Method POST -Uri $uri `
        -Headers @{ 'X-Showtime-Token' = $liveToken } `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) `
        -UseBasicParsing -TimeoutSec 30
      $parsed = $null
      try { $parsed = $resp.Content | ConvertFrom-Json } catch { $parsed = @{ status = 'ok'; raw = $resp.Content } }
      Log ("OK $act status=$($parsed.status) http=$($resp.StatusCode)")
      return $parsed
    } catch {
      $lastErr = $_
      $msg = [string]$_.Exception.Message
      $detail = ''
      try {
        $er = $_.ErrorDetails.Message
        if ($er) { $detail = $er }
      } catch {}
      try {
        $respObj = $_.Exception.Response
        if ($respObj -and $respObj.GetResponseStream) {
          $sr = New-Object System.IO.StreamReader($respObj.GetResponseStream())
          $detail = $sr.ReadToEnd()
          $sr.Close()
        }
      } catch {}
      Log ("FAIL $act attempt=$attempt msg=$msg detail=$detail")
      if ($attempt -lt 2) {
        Start-Sleep -Milliseconds 500
        $liveToken = Read-ShowTimeToken
        $livePort = Read-ShowTimePort
        $uri = "http://127.0.0.1:$livePort/api/join-requests/$([uri]::EscapeDataString($script:joinId))/$act"
        Log ("RETRY with fresh tokenLen=$($liveToken.Length) port=$livePort")
        continue
      }
    }
  }
  $hint = 'Open board and Approve there if this keeps failing.'
  if ($lastErr) {
    $em = [string]$lastErr.Exception.Message
    if ($em -match '401|Unauthorized|bad token|missing') {
      throw "Auth failed (token). $hint"
    }
    throw "$em — $hint"
  }
  throw "approve/deny failed — $hint"
}

$script:acted = $false

function Get-BoardUrlNow {
  $u = $script:boardUrl
  if (-not $u -or $u -notmatch '://') {
    $u = "http://127.0.0.1:$(Read-ShowTimePort)/"
  }
  return $u
}

function Open-BoardAlways {
  <# Always-works path when OS "popups" are blocked / Focus Assist / WinForms fails.
     Browser popup-blockers do NOT apply to this (Start-Process of http URL).
     The board join-gate banner stays until APPROVE/DENY. #>
  try {
    $u = Get-BoardUrlNow
    Start-Process $u
    Log ('open-board always ' + $u)
    return $true
  } catch {
    Log ('open-board fail: ' + $_)
    return $false
  }
}

function Write-JoinNeedsApproveFile {
  # Loud file even if every GUI channel is suppressed
  try {
    $path = Join-Path $script:state 'JOIN-NEEDS-APPROVE.md'
    $u = Get-BoardUrlNow
    $md = @(
      '# SHOW TIME — JOIN NEEDS APPROVE'
      ''
      '| | |'
      '|--|--|'
      "| When | ``$((Get-Date).ToString('o'))`` |"
      "| Join id | ``$($script:joinId)`` |"
      "| Repo | ``$($script:repoId)`` |"
      "| Branch | ``$($script:branch)`` |"
      "| Session | ``$($script:sessionId)`` |"
      "| Ledger | $($script:ledgerTitle) |"
      "| Path | ``$($script:repoPath)`` |"
      "| Board | $u |"
      ''
      '## What to do'
      ''
      '1. Open the board (link above) — the gold **JOIN REQUESTS** banner stays until you decide.'
      '2. Click **APPROVE** or **DENY** on the board (or the bottom-right desktop dialog if it is showing).'
      '3. Browser popup blockers do **not** block this — use the board tab if the OS dialog is hidden.'
      ''
      'Arm / fleet work **does not start** until APPROVE.'
    ) -join "`n"
    Set-Content -LiteralPath $path -Value $md -Encoding utf8
    # Also append to chat-inbox style trail
    $line = (@{
        kind = 'join-needs-approve'
        joinId = $script:joinId
        repoId = $script:repoId
        sessionId = $script:sessionId
        boardUrl = $u
        at = (Get-Date).ToString('o')
        needsHuman = $true
      } | ConvertTo-Json -Compress)
    Add-Content -LiteralPath (Join-Path $script:state 'chat-inbox.jsonl') -Value $line -Encoding utf8
    Log ('wrote JOIN-NEEDS-APPROVE.md')
  } catch { Log ('needs-approve file fail: ' + $_) }
}

function Test-JoinResolved {
  # True when join is no longer pending (approved/denied on board while dialog open)
  if (-not $script:joinId) { return $false }
  try {
    $tok = Read-ShowTimeToken
    $port = Read-ShowTimePort
    if (-not $tok) { return $false }
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/api/join-requests/$($script:joinId)" `
      -Headers @{ 'X-Showtime-Token' = $tok } -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
    $j = $r.Content | ConvertFrom-Json
    $st = if ($j.request) { [string]$j.request.status } elseif ($j.status) { [string]$j.status } else { '' }
    if ($st -and $st -ne 'pending') {
      Log ("join resolved externally status=$st")
      return $true
    }
  } catch {}
  return $false
}

function Place-FormBottomRight([System.Windows.Forms.Form]$form) {
  # Primary working area bottom-right — multi-monitor safe
  try {
    $screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
    if (-not $screen) { $screen = [System.Windows.Forms.Screen]::PrimaryScreen }
    $wa = $screen.WorkingArea
    $form.Location = New-Object System.Drawing.Point(
      ($wa.Right - $form.Width - 16),
      ($wa.Bottom - $form.Height - 16)
    )
  } catch {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point(
      ($wa.Right - $form.Width - 16),
      ($wa.Bottom - $form.Height - 16)
    )
  }
}

# Always: loud file + open board (works if WinForms/toasts are suppressed)
Write-JoinNeedsApproveFile
Open-BoardAlways | Out-Null

try {
  Add-Type -AssemblyName System.Windows.Forms | Out-Null
  Add-Type -AssemblyName System.Drawing | Out-Null

  $form = New-Object System.Windows.Forms.Form
  $form.Text = 'SHOW TIME — JOIN (stays until APPROVE/DENY)'
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $form.Size = New-Object System.Drawing.Size(420, 300)
  $form.MaximizeBox = $false
  $form.MinimizeBox = $true   # allow minimize; re-nudge brings it back
  $form.TopMost = $true
  $form.ShowInTaskbar = $true
  $form.BackColor = [System.Drawing.Color]::FromArgb(18, 16, 12)
  $form.ForeColor = [System.Drawing.Color]::FromArgb(245, 230, 200)
  $form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
  Place-FormBottomRight $form
  $form.Add_Shown({
      Place-FormBottomRight $form
      try { $form.TopMost = $true; $form.Activate(); $form.BringToFront() } catch {}
    })

  $lblHead = New-Object System.Windows.Forms.Label
  $lblHead.Text = '🔐 JOIN REQUEST'
  $lblHead.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
  $lblHead.ForeColor = [System.Drawing.Color]::FromArgb(240, 192, 64)
  $lblHead.Location = New-Object System.Drawing.Point(14, 12)
  $lblHead.Size = New-Object System.Drawing.Size(380, 24)
  $form.Controls.Add($lblHead)

  $repoLine = if ($script:repoId) { $script:repoId } else { 'unknown repo' }
  if ($script:branch) { $repoLine = "$repoLine  ·  $($script:branch)" }
  $lblRepo = New-Object System.Windows.Forms.Label
  $lblRepo.Text = $repoLine
  $lblRepo.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
  $lblRepo.ForeColor = [System.Drawing.Color]::FromArgb(255, 236, 170)
  $lblRepo.Location = New-Object System.Drawing.Point(14, 42)
  $lblRepo.Size = New-Object System.Drawing.Size(380, 24)
  $form.Controls.Add($lblRepo)

  $subBits = @()
  if ($script:ledgerTitle) { $subBits += $script:ledgerTitle }
  if ($script:sessionId) { $subBits += $script:sessionId }
  if ($script:repoPath) { $subBits += $script:repoPath }
  $lblSub = New-Object System.Windows.Forms.Label
  $lblSub.Text = if ($subBits.Count) { ($subBits -join "`n") } else { $script:body }
  $lblSub.ForeColor = [System.Drawing.Color]::FromArgb(180, 170, 150)
  $lblSub.Location = New-Object System.Drawing.Point(14, 70)
  $lblSub.Size = New-Object System.Drawing.Size(380, 52)
  $form.Controls.Add($lblSub)

  $hasJoin = [bool]$script:joinId
  $hasTok = [bool](Read-ShowTimeToken)
  $lblStatus = New-Object System.Windows.Forms.Label
  $lblStatus.Text = if ($hasJoin -and $hasTok) {
    'Bottom-right · stays until APPROVE/DENY · board also works'
  } elseif (-not $hasJoin) {
    'Missing join id — use Open board (banner on localhost).'
  } else {
    'No server.token yet — open board once, then Approve on the gold banner.'
  }
  $lblStatus.Location = New-Object System.Drawing.Point(14, 126)
  $lblStatus.Size = New-Object System.Drawing.Size(380, 36)
  $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(160, 150, 130)
  $form.Controls.Add($lblStatus)

  $btnApprove = New-Object System.Windows.Forms.Button
  $btnApprove.Text = 'APPROVE'
  $btnApprove.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
  $btnApprove.BackColor = [System.Drawing.Color]::FromArgb(34, 120, 56)
  $btnApprove.ForeColor = [System.Drawing.Color]::White
  $btnApprove.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $btnApprove.Location = New-Object System.Drawing.Point(14, 168)
  $btnApprove.Size = New-Object System.Drawing.Size(180, 48)
  $btnApprove.Enabled = $hasJoin
  $form.Controls.Add($btnApprove)

  $btnDeny = New-Object System.Windows.Forms.Button
  $btnDeny.Text = 'DENY'
  $btnDeny.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
  $btnDeny.BackColor = [System.Drawing.Color]::FromArgb(140, 40, 40)
  $btnDeny.ForeColor = [System.Drawing.Color]::White
  $btnDeny.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $btnDeny.Location = New-Object System.Drawing.Point(210, 168)
  $btnDeny.Size = New-Object System.Drawing.Size(180, 48)
  $btnDeny.Enabled = $hasJoin
  $form.Controls.Add($btnDeny)

  $btnBoard = New-Object System.Windows.Forms.LinkLabel
  $btnBoard.Text = 'Open board (works if this dialog is blocked/hidden)'
  $btnBoard.LinkColor = [System.Drawing.Color]::FromArgb(100, 200, 220)
  $btnBoard.Location = New-Object System.Drawing.Point(14, 228)
  $btnBoard.Size = New-Object System.Drawing.Size(380, 18)
  $btnBoard.Add_LinkClicked({
      try { Open-BoardAlways | Out-Null } catch { Log ('open board fail: ' + $_) }
    })
  $form.Controls.Add($btnBoard)

  $btnApprove.Add_Click({
      $btnApprove.Enabled = $false
      $btnDeny.Enabled = $false
      $lblStatus.Text = 'Approving…'
      $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(180, 220, 140)
      try {
        $null = Invoke-JoinAct 'approve'
        $script:acted = $true
        $lblStatus.Text = 'APPROVED — fleet on board'
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 120)
        Log 'popup APPROVE ok'
        Start-Sleep -Milliseconds 600
        $form.Close()
      } catch {
        Log ('popup APPROVE fail: ' + $_)
        $short = [string]$_.Exception.Message
        if ($short.Length -gt 90) { $short = $short.Substring(0, 90) + '…' }
        $lblStatus.Text = 'Failed: ' + $short
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 140, 120)
        $btnApprove.Enabled = $true
        $btnDeny.Enabled = $true
      }
    })

  $btnDeny.Add_Click({
      $btnApprove.Enabled = $false
      $btnDeny.Enabled = $false
      $lblStatus.Text = 'Denying…'
      try {
        $null = Invoke-JoinAct 'deny'
        $script:acted = $true
        $lblStatus.Text = 'DENIED'
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 140, 120)
        Log 'popup DENY ok'
        Start-Sleep -Milliseconds 600
        $form.Close()
      } catch {
        Log ('popup DENY fail: ' + $_)
        $short = [string]$_.Exception.Message
        if ($short.Length -gt 90) { $short = $short.Substring(0, 90) + '…' }
        $lblStatus.Text = 'Failed: ' + $short
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 140, 120)
        $btnApprove.Enabled = $true
        $btnDeny.Enabled = $true
      }
    })

  # Stay on screen until APPROVE or DENY — no auto-timeout.
  # (Old 10-minute timer closed the dialog while the join was still pending.)
  $form.ControlBox = $true  # allow X, but we intercept it below
  $form.Add_FormClosing({
      param($sender, $e)
      if ($script:acted) { return }
      # Block Alt+F4 / X / OS close until operator decides
      $e.Cancel = $true
      $lblStatus.Text = 'Still waiting — click APPROVE or DENY (will not dismiss itself).'
      $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 200, 100)
      try { $form.TopMost = $true; $form.Activate() } catch {}
      Log 'popup close blocked — not approved/denied yet'
    })

  # Re-assert bottom-right + topmost; also close if approved on the board instead
  $nudgeTimer = New-Object System.Windows.Forms.Timer
  $nudgeTimer.Interval = 4 * 1000
  $nudgeTimer.Add_Tick({
      if ($script:acted) { $nudgeTimer.Stop(); return }
      try {
        if (Test-JoinResolved) {
          $script:acted = $true
          $lblStatus.Text = 'Resolved on board — closing'
          $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 120)
          $nudgeTimer.Stop()
          $form.Close()
          return
        }
        Place-FormBottomRight $form
        $form.TopMost = $true
        # Don't steal focus every 4s (annoying) — only re-pin location/topmost
      } catch {}
    })
  $nudgeTimer.Start()

  Log ('popup shown joinId=' + $script:joinId + ' repo=' + $script:repoId + ' sticky=bottom-right-until-approve')
  [void]$form.ShowDialog()
  try { $nudgeTimer.Stop(); $nudgeTimer.Dispose() } catch {}
  $form.Dispose()
  Log ('popup closed acted=' + $script:acted)
} catch {
  Log ('popup fail: ' + $_)
  # Fallback stack when WinForms dialog cannot show (blocked / no desktop / headless):
  # 1) Board already opened + JOIN-NEEDS-APPROVE.md written
  # 2) System modal MessageBox (not a browser popup — still works under many "block popups" settings)
  # 3) Sticky tray balloon best-effort
  try {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $u = Get-BoardUrlNow
    $msg = @"
SHOW TIME join needs a human decision.

Repo: $($script:repoId)  $($script:branch)
$($script:ledgerTitle)

YES = APPROVE on the server
NO  = DENY
CANCEL = only open the board (gold JOIN banner)

Board (always works): $u
File: %USERPROFILE%\.claude\scratch\autopro-theater\JOIN-NEEDS-APPROVE.md

Browser "block popups" does NOT stop the board tab.
"@
    $r = [System.Windows.Forms.MessageBox]::Show(
      $msg,
      'SHOW TIME — JOIN (fallback)',
      [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
      [System.Windows.Forms.MessageBoxIcon]::Warning,
      [System.Windows.Forms.MessageBoxDefaultButton]::Button1
    )
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes -and $script:joinId) {
      try {
        $null = Invoke-JoinAct 'approve'
        $script:acted = $true
        Log 'fallback MessageBox APPROVE ok'
      } catch { Log ('fallback APPROVE fail: ' + $_) }
    } elseif ($r -eq [System.Windows.Forms.DialogResult]::No -and $script:joinId) {
      try {
        $null = Invoke-JoinAct 'deny'
        $script:acted = $true
        Log 'fallback MessageBox DENY ok'
      } catch { Log ('fallback DENY fail: ' + $_) }
    } else {
      Open-BoardAlways | Out-Null
      Log 'fallback MessageBox → open board only'
    }
  } catch {
    Log ('fallback MessageBox fail: ' + $_)
    try {
      $ni = New-Object System.Windows.Forms.NotifyIcon
      $ni.Icon = [System.Drawing.SystemIcons]::Warning
      $ni.Visible = $true
      $ni.Text = 'SHOW TIME join needs Approve'
      $ni.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
      $ni.BalloonTipTitle = $script:title
      $ni.BalloonTipText = ($script:body + ' · Open board: gold JOIN banner · JOIN-NEEDS-APPROVE.md')
      $ni.ShowBalloonTip(30000)
      Open-BoardAlways | Out-Null
      # Keep tray icon briefly so Focus Assist users still see a shell affordance
      Start-Sleep -Seconds 20
      $ni.Visible = $false
      $ni.Dispose()
    } catch { Log ('balloon fail: ' + $_) }
  }
}

Log 'join-alarm done (once)'
