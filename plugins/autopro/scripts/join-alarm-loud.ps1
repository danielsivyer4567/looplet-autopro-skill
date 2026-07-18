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

# --- sound once ---
$media = Join-Path $env:WINDIR 'Media'
$names = @('Alarm01.wav', 'Alarm02.wav', 'Windows Notify.wav', 'Ring01.wav')
$wav = $null
foreach ($n in $names) {
  $p = Join-Path $media $n
  if (Test-Path -LiteralPath $p) { $wav = $p; break }
}
if ($wav) {
  try {
    $player = New-Object System.Media.SoundPlayer $wav
    $player.Load()
    $player.Play()
    Log ('play-once ' + $wav)
  } catch { Log ('play fail: ' + $_) }
} else {
  Log 'NO WAV FILES'
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
try {
  Add-Type -AssemblyName System.Windows.Forms | Out-Null
  Add-Type -AssemblyName System.Drawing | Out-Null

  $form = New-Object System.Windows.Forms.Form
  $form.Text = 'SHOW TIME — JOIN'
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $form.Size = New-Object System.Drawing.Size(420, 270)
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.TopMost = $true
  $form.ShowInTaskbar = $true
  $form.BackColor = [System.Drawing.Color]::FromArgb(18, 16, 12)
  $form.ForeColor = [System.Drawing.Color]::FromArgb(245, 230, 200)
  $form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)

  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $form.Location = New-Object System.Drawing.Point(
    ($wa.Right - $form.Width - 16),
    ($wa.Bottom - $form.Height - 16)
  )

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
    'Approve this fleet onto the board, or deny it.'
  } elseif (-not $hasJoin) {
    'Missing join id — use Open board.'
  } else {
    'No server.token yet — open the board once, then Approve.'
  }
  $lblStatus.Location = New-Object System.Drawing.Point(14, 126)
  $lblStatus.Size = New-Object System.Drawing.Size(380, 22)
  $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(160, 150, 130)
  $form.Controls.Add($lblStatus)

  $btnApprove = New-Object System.Windows.Forms.Button
  $btnApprove.Text = 'APPROVE'
  $btnApprove.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
  $btnApprove.BackColor = [System.Drawing.Color]::FromArgb(34, 120, 56)
  $btnApprove.ForeColor = [System.Drawing.Color]::White
  $btnApprove.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $btnApprove.Location = New-Object System.Drawing.Point(14, 158)
  $btnApprove.Size = New-Object System.Drawing.Size(180, 48)
  $btnApprove.Enabled = $hasJoin
  $form.Controls.Add($btnApprove)

  $btnDeny = New-Object System.Windows.Forms.Button
  $btnDeny.Text = 'DENY'
  $btnDeny.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
  $btnDeny.BackColor = [System.Drawing.Color]::FromArgb(140, 40, 40)
  $btnDeny.ForeColor = [System.Drawing.Color]::White
  $btnDeny.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $btnDeny.Location = New-Object System.Drawing.Point(210, 158)
  $btnDeny.Size = New-Object System.Drawing.Size(180, 48)
  $btnDeny.Enabled = $hasJoin
  $form.Controls.Add($btnDeny)

  $btnBoard = New-Object System.Windows.Forms.LinkLabel
  $btnBoard.Text = 'Open board (always works)'
  $btnBoard.LinkColor = [System.Drawing.Color]::FromArgb(100, 200, 220)
  $btnBoard.Location = New-Object System.Drawing.Point(14, 216)
  $btnBoard.Size = New-Object System.Drawing.Size(220, 18)
  $btnBoard.Add_LinkClicked({
      try {
        $u = $script:boardUrl
        if (-not $u) { $u = "http://127.0.0.1:$(Read-ShowTimePort)/" }
        Start-Process $u
      } catch { Log ('open board fail: ' + $_) }
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

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 10 * 60 * 1000
  $timer.Add_Tick({ $timer.Stop(); $form.Close() })
  $timer.Start()

  Log ('popup shown joinId=' + $script:joinId + ' repo=' + $script:repoId)
  [void]$form.ShowDialog()
  $timer.Stop()
  $timer.Dispose()
  $form.Dispose()
  Log ('popup closed acted=' + $script:acted)
} catch {
  Log ('popup fail: ' + $_)
  try {
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = [System.Drawing.SystemIcons]::Information
    $ni.Visible = $true
    $ni.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $ni.BalloonTipTitle = $script:title
    $ni.BalloonTipText = ($script:body + ' · Open board to Approve/Deny')
    $ni.ShowBalloonTip(10000)
    Start-Sleep -Seconds 8
    $ni.Visible = $false
    $ni.Dispose()
  } catch { Log ('balloon fail: ' + $_) }
}

Log 'join-alarm done (once)'
