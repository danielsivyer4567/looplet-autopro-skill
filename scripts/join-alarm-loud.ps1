# join-alarm-loud.ps1 — ONE short WAV + bottom-right Approve/Deny popup.
# Payload: %USERPROFILE%\.claude\scratch\autopro-theater\join-alarm-payload.json
# Posts approve/deny to local theater with server.token — no board navigation required.
$ErrorActionPreference = 'Continue'
$state = Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater'
$log = Join-Path $state 'join-alarm.log'
$payloadPath = Join-Path $state 'join-alarm-payload.json'
function Log([string]$m) {
  try { Add-Content -LiteralPath $log -Value ((Get-Date -Format o) + ' ' + $m) -Encoding utf8 } catch {}
}
Log 'join-alarm start (once + action popup)'

$title = 'SHOW TIME — JOIN REQUEST'
$body = 'Approve or deny this fleet'
$joinId = ''
$repoId = ''
$branch = ''
$ledgerTitle = ''
$repoPath = ''
$sessionId = ''
$boardUrl = 'http://127.0.0.1:8770/'
$port = ''
try {
  if (Test-Path -LiteralPath $payloadPath) {
    $j = Get-Content -LiteralPath $payloadPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($j.title) { $title = [string]$j.title }
    if ($j.body) { $body = [string]$j.body }
    if ($j.joinId) { $joinId = [string]$j.joinId }
    if ($j.repoId) { $repoId = [string]$j.repoId }
    if ($j.branch) { $branch = [string]$j.branch }
    if ($j.ledgerTitle) { $ledgerTitle = [string]$j.ledgerTitle }
    if ($j.repoPath) { $repoPath = [string]$j.repoPath }
    if ($j.sessionId) { $sessionId = [string]$j.sessionId }
    if ($j.boardUrl) { $boardUrl = [string]$j.boardUrl }
    if ($j.port) { $port = [string]$j.port }
  }
} catch { Log ('payload fail: ' + $_) }

if (-not $port) {
  try {
    $pf = Join-Path $state 'server.port'
    if (Test-Path -LiteralPath $pf) { $port = (Get-Content -LiteralPath $pf -Raw).Trim() }
  } catch {}
}
if (-not $port) { $port = '8770' }
if ($boardUrl -notmatch '://') { $boardUrl = "http://127.0.0.1:$port/" }

$token = ''
try {
  $tf = Join-Path $state 'server.token'
  if (Test-Path -LiteralPath $tf) { $token = (Get-Content -LiteralPath $tf -Raw).Trim() }
} catch {}

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
    $player.Play()  # async so form can show immediately
    Log ('play-once ' + $wav)
  } catch { Log ('play fail: ' + $_) }
} else {
  Log 'NO WAV FILES'
}

# --- action popup (bottom-right): big APPROVE / DENY ---
function Invoke-JoinAct([string]$act) {
  if (-not $joinId) { throw 'missing joinId in payload' }
  if (-not $token) { throw 'missing server.token — is Show Time running?' }
  $uri = "http://127.0.0.1:$port/api/join-requests/$([uri]::EscapeDataString($joinId))/$act"
  $headers = @{ 'X-Showtime-Token' = $token }
  $payload = if ($act -eq 'deny') {
    '{"by":"os-toast","reason":"denied from join popup"}'
  } else {
    '{"by":"os-toast"}'
  }
  Log ("POST $act joinId=$joinId port=$port")
  $resp = Invoke-RestMethod -Method POST -Uri $uri -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $payload -TimeoutSec 30
  Log ("OK $act status=$($resp.status)")
  return $resp
}

$acted = $false
try {
  Add-Type -AssemblyName System.Windows.Forms | Out-Null
  Add-Type -AssemblyName System.Drawing | Out-Null

  $form = New-Object System.Windows.Forms.Form
  $form.Text = 'SHOW TIME — JOIN'
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
  $form.Size = New-Object System.Drawing.Size(400, 248)
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.TopMost = $true
  $form.ShowInTaskbar = $true
  $form.BackColor = [System.Drawing.Color]::FromArgb(18, 16, 12)
  $form.ForeColor = [System.Drawing.Color]::FromArgb(245, 230, 200)
  $form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)

  # Bottom-right of primary work area
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
  $lblHead.Size = New-Object System.Drawing.Size(360, 24)
  $form.Controls.Add($lblHead)

  $repoLine = if ($repoId) { $repoId } else { 'unknown repo' }
  if ($branch) { $repoLine = "$repoLine  ·  $branch" }
  $lblRepo = New-Object System.Windows.Forms.Label
  $lblRepo.Text = $repoLine
  $lblRepo.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
  $lblRepo.ForeColor = [System.Drawing.Color]::FromArgb(255, 236, 170)
  $lblRepo.Location = New-Object System.Drawing.Point(14, 42)
  $lblRepo.Size = New-Object System.Drawing.Size(360, 24)
  $form.Controls.Add($lblRepo)

  $subBits = @()
  if ($ledgerTitle) { $subBits += $ledgerTitle }
  if ($sessionId) { $subBits += $sessionId }
  if ($repoPath) { $subBits += $repoPath }
  $lblSub = New-Object System.Windows.Forms.Label
  $lblSub.Text = if ($subBits.Count) { ($subBits -join "`n") } else { $body }
  $lblSub.ForeColor = [System.Drawing.Color]::FromArgb(180, 170, 150)
  $lblSub.Location = New-Object System.Drawing.Point(14, 70)
  $lblSub.Size = New-Object System.Drawing.Size(360, 48)
  $form.Controls.Add($lblSub)

  $lblStatus = New-Object System.Windows.Forms.Label
  $lblStatus.Text = if ($joinId -and $token) { 'Approve this fleet onto the board, or deny it.' } else { 'Missing join id/token — open the board.' }
  $lblStatus.Location = New-Object System.Drawing.Point(14, 122)
  $lblStatus.Size = New-Object System.Drawing.Size(360, 20)
  $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(160, 150, 130)
  $form.Controls.Add($lblStatus)

  $btnApprove = New-Object System.Windows.Forms.Button
  $btnApprove.Text = 'APPROVE'
  $btnApprove.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
  $btnApprove.BackColor = [System.Drawing.Color]::FromArgb(34, 120, 56)
  $btnApprove.ForeColor = [System.Drawing.Color]::White
  $btnApprove.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $btnApprove.Location = New-Object System.Drawing.Point(14, 152)
  $btnApprove.Size = New-Object System.Drawing.Size(170, 48)
  $btnApprove.Enabled = [bool]($joinId -and $token)
  $form.Controls.Add($btnApprove)

  $btnDeny = New-Object System.Windows.Forms.Button
  $btnDeny.Text = 'DENY'
  $btnDeny.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
  $btnDeny.BackColor = [System.Drawing.Color]::FromArgb(140, 40, 40)
  $btnDeny.ForeColor = [System.Drawing.Color]::White
  $btnDeny.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
  $btnDeny.Location = New-Object System.Drawing.Point(200, 152)
  $btnDeny.Size = New-Object System.Drawing.Size(170, 48)
  $btnDeny.Enabled = [bool]($joinId -and $token)
  $form.Controls.Add($btnDeny)

  $btnBoard = New-Object System.Windows.Forms.LinkLabel
  $btnBoard.Text = 'Open board'
  $btnBoard.LinkColor = [System.Drawing.Color]::FromArgb(100, 200, 220)
  $btnBoard.Location = New-Object System.Drawing.Point(14, 204)
  $btnBoard.Size = New-Object System.Drawing.Size(120, 18)
  $btnBoard.Add_LinkClicked({
      try { Start-Process $boardUrl } catch { Log ('open board fail: ' + $_) }
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
        Start-Sleep -Milliseconds 700
        $form.Close()
      } catch {
        Log ('popup APPROVE fail: ' + $_)
        $lblStatus.Text = 'Approve failed: ' + $_.Exception.Message
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
        Start-Sleep -Milliseconds 700
        $form.Close()
      } catch {
        Log ('popup DENY fail: ' + $_)
        $lblStatus.Text = 'Deny failed: ' + $_.Exception.Message
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(255, 140, 120)
        $btnApprove.Enabled = $true
        $btnDeny.Enabled = $true
      }
    })

  # Auto-dismiss after 10 minutes if ignored (leave pending on board)
  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 10 * 60 * 1000
  $timer.Add_Tick({ $timer.Stop(); $form.Close() })
  $timer.Start()

  Log ('popup shown joinId=' + $joinId + ' repo=' + $repoId)
  [void]$form.ShowDialog()
  $timer.Stop()
  $timer.Dispose()
  $form.Dispose()
  Log ('popup closed acted=' + $acted)
} catch {
  Log ('popup fail: ' + $_)
  # Fallback: classic balloon only
  try {
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $ni.Icon = [System.Drawing.SystemIcons]::Information
    $ni.Visible = $true
    $ni.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $ni.BalloonTipTitle = $title
    $ni.BalloonTipText = ($body + ' · Open board to Approve/Deny')
    $ni.ShowBalloonTip(10000)
    Start-Sleep -Seconds 8
    $ni.Visible = $false
    $ni.Dispose()
  } catch { Log ('balloon fail: ' + $_) }
}

Log 'join-alarm done (once)'
