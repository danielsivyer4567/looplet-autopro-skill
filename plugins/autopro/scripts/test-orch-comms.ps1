#Requires -Version 7.0
<#
  test-orch-comms.ps1 — prove every operator ↔ ORCH ↔ SA communication path.

  Covers (live against Show Time on :8770):
    1. Notes: operator → SA transcript
    2. Notes: ORCH/worker → operator (speech-bubble source)
    3. Questions: SA hold via ORCH + Answer SA
    4. Steers: Tell SA + consume-steers
    5. Nudge: listen window + ack on progress
    6. UI: speech bubble, desk ledges, Tell SA / Answer SA markers
    7. Speech bubble click targets + NOTES/HOLD tabs

  Usage:
    pwsh -NoProfile -File test-orch-comms.ps1
#>
$ErrorActionPreference = 'Stop'
$SkillScripts = $PSScriptRoot
$fail = 0
function Ok([string]$m) { Write-Output ("  OK  {0}" -f $m) }
function Bad([string]$m) { Write-Output ("  FAIL {0}" -f $m); $script:fail++ }

Write-Output '==== ORCH comms test ===='

# Ensure board
& pwsh -NoProfile -File (Join-Path $SkillScripts 'theater-register.ps1') -Action ensure 2>&1 | Out-Null
$base = 'http://127.0.0.1:8770'
$portFile = Join-Path ($env:USERPROFILE ?? $HOME) '.claude/scratch/autopro-theater/server.port'
if (Test-Path -LiteralPath $portFile) {
  $p = (Get-Content -LiteralPath $portFile -Raw).Trim()
  if ($p -match '^\d+$') { $base = "http://127.0.0.1:$p" }
}
$tokFile = Join-Path ($env:USERPROFILE ?? $HOME) '.claude/scratch/autopro-theater/server.token'
$tok = if (Test-Path $tokFile) { (Get-Content $tokFile -Raw).Trim() } else { '' }
if (-not $tok) { Bad 'no server.token'; Write-Output 'ORCH_COMMS=red'; exit 1 }
$H = @{ 'X-Showtime-Token' = $tok }
$CT = 'application/json'
Write-Output ("board={0}" -f $base)

$sid = 'v2a_orch' + [guid]::NewGuid().ToString('N').Substring(0, 6)
# Real temp repo path (join identity requires a folder name)
$repoPath = Join-Path $env:TEMP ("orch-comms-" + $sid)
New-Item -ItemType Directory -Force -Path (Join-Path $repoPath '.claude\scratch') | Out-Null
$reg = [ordered]@{
  sessionId   = $sid
  repoId      = 'orchcommstest'
  repoPath    = $repoPath
  primaryRepoPath = $repoPath
  branch      = 'test/orch-comms'
  status      = 'running'
  ledgerTitle = 'ORCH comms proof ledger'
  ledgerPath  = (Join-Path $repoPath '.claude\scratch\ledger.md')
  pid         = $PID
  runnerPid   = $PID
  todo        = @(
    @{ id = 'SC-01'; text = 'Comms slice'; state = 'in-progress' }
  )
}
$regJson = $reg | ConvertTo-Json -Depth 6

try {
  # Door A: join-request → approve → session (same as production / test-showtime)
  $jr = Invoke-RestMethod -Method POST -Uri "$base/api/join-requests" -Headers $H -ContentType $CT -Body $regJson -TimeoutSec 10
  $jid = $null
  if ($jr.request -and $jr.request.id) { $jid = [string]$jr.request.id }
  if ($jid -and $jr.status -eq 'pending') {
    $null = Invoke-RestMethod -Method POST -Uri "$base/api/join-requests/$jid/approve" -Headers $H -ContentType $CT -Body '{"by":"test-orch-comms"}' -TimeoutSec 30
  }
  $null = Invoke-RestMethod -Method POST -Uri "$base/api/sessions" -Headers $H -ContentType $CT -Body $regJson -TimeoutSec 10
  Ok "registered $sid (join+approve)"
} catch {
  Bad "register $($_.Exception.Message)"
  Write-Output 'ORCH_COMMS=red'
  exit 1
}

# --- 1) Operator note ---
try {
  $b = @{ text = 'OPERATOR → SA: hurry up on SC-01'; from = 'operator' } | ConvertTo-Json
  $r = Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sid/notes" -Headers $H -ContentType $CT -Body $b -TimeoutSec 8
  $hit = @($r.session.notes) | Where-Object { $_.text -match 'hurry up' -and $_.from -match 'operator' } | Select-Object -First 1
  if ($hit) { Ok 'operator note lands in transcript' } else { Bad 'operator note missing' }
} catch { Bad "operator note $_" }

# --- 2) ORCH says (speech bubble source) ---
try {
  $b = @{ text = 'Need your call: ship SC-01 with the mock path or wait for real API?'; from = 'orch'; kind = 'say' } | ConvertTo-Json
  $r = Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sid/notes" -Headers $H -ContentType $CT -Body $b -TimeoutSec 8
  $hit = @($r.session.notes) | Where-Object { $_.text -match 'ship SC-01' -and $_.from -eq 'orch' } | Select-Object -First 1
  if ($hit) { Ok 'ORCH note (speech source) lands' } else { Bad 'ORCH note missing' }
  if ($r.session.orchSpeech -and $r.session.orchSpeech.text -match 'ship SC-01') {
    Ok 'session.orchSpeech set for bubble'
  } else { Bad 'session.orchSpeech missing after ORCH note' }
} catch { Bad "orch note $_" }

# --- 3) Worker report via ORCH ---
try {
  $b = @{ text = 'Worker finished unit tests green'; from = 'worker' } | ConvertTo-Json
  $r = Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sid/notes" -Headers $H -ContentType $CT -Body $b -TimeoutSec 8
  $hit = @($r.session.notes) | Where-Object { $_.from -eq 'worker' -and $_.text -match 'unit tests' } | Select-Object -First 1
  if ($hit) { Ok 'worker report note lands' } else { Bad 'worker report missing' }
} catch { Bad "worker note $_" }

# --- 4) Question hold (SA → ORCH → you) ---
$qid = $null
try {
  $b = @{ text = 'Approve merge of SC-01?'; chips = @('Yes', 'No', 'Later') } | ConvertTo-Json
  $r = Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sid/questions" -Headers $H -ContentType $CT -Body $b -TimeoutSec 8
  if ($r.session.needsInput -or $r.session.status -eq 'needs_input') { Ok 'question sets needs_input' } else { Bad 'needs_input not set' }
  $q = @($r.session.questions) | Where-Object { $_.status -eq 'open' } | Select-Object -First 1
  if ($q) { $qid = $q.id; Ok "open hold qid=$qid" } else { Bad 'no open question' }
  # Mirrored into notes as from=orch kind=hold
  $mirror = @($r.session.notes) | Where-Object { $_.kind -eq 'hold' -or ($_.from -eq 'orch' -and $_.text -match 'Approve merge') } | Select-Object -First 1
  if ($mirror) { Ok 'hold mirrored into notes for bubble/desk' } else { Bad 'hold not mirrored to notes' }
  if ($r.session.orchSpeech -and $r.session.orchSpeech.kind -eq 'hold') {
    Ok 'orchSpeech kind=hold for bubble pulse'
  } else { Bad 'orchSpeech not hold after question' }
} catch { Bad "question $_" }

# --- 5) Answer SA ---
try {
  if (-not $qid) { throw 'no qid' }
  $b = @{ questionId = $qid; answer = 'Yes — merge SC-01' } | ConvertTo-Json
  $r = Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sid/questions" -Headers $H -ContentType $CT -Body $b -TimeoutSec 8
  $closed = @($r.session.questions) | Where-Object { $_.id -eq $qid -and $_.status -eq 'answered' } | Select-Object -First 1
  if ($closed -and $closed.answer -match 'Yes') { Ok 'answer SA closes hold' } else { Bad 'answer did not close hold' }
  $ack = @($r.session.notes) | Where-Object { $_.from -eq 'orch' -and $_.text -match 'relayed your answer' } | Select-Object -First 1
  if ($ack) { Ok 'ORCH ack note after answer' } else { Bad 'ORCH ack note missing' }
  $you = @($r.session.notes) | Where-Object { $_.from -eq 'operator' -and $_.text -match 'You → ORCH' } | Select-Object -First 1
  if ($you) { Ok 'operator answer line in transcript' } else { Bad 'operator answer line missing' }
} catch { Bad "answer $_" }

# --- 6) Steer (Tell SA) ---
try {
  $b = @{ text = 'Prefer dry-run only'; target = 'SC-01' } | ConvertTo-Json
  $null = Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sid/steers" -Headers $H -ContentType $CT -Body $b -TimeoutSec 8
  $cs = Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sid/consume-steers" -Headers $H -ContentType $CT -Body '{}' -TimeoutSec 8
  if (@($cs.steers).Count -ge 1) { Ok 'steer + consume-steers' } else { Bad 'steer consume empty' }
} catch { Bad "steer $_" }

# --- 7) Nudge ---
try {
  $n = Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sid/nudge" -Headers $H -ContentType $CT -Body '{"listenSec":30}' -TimeoutSec 8
  if ($n.nudge.status -eq 'listening') { Ok 'nudge listening' } else { Bad "nudge status=$($n.nudge.status)" }
  $null = Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sid/heartbeat" -Headers $H -ContentType $CT -Body (@{
    status = 'running'; progress = $true; pid = $PID; runnerPid = $PID
  } | ConvertTo-Json) -TimeoutSec 8
  $list = Invoke-RestMethod -Uri "$base/api/sessions" -Headers $H -TimeoutSec 8
  $sess = @($list.sessions) | Where-Object { $_.sessionId -eq $sid } | Select-Object -First 1
  if ($sess.nudge.status -eq 'acked') { Ok 'nudge acked on progress' } else { Bad "nudge ack=$($sess.nudge.status)" }
} catch { Bad "nudge $_" }

# --- 8) UI markers (disk source + live HTML) ---
try {
  $indexPath = Join-Path (Split-Path $SkillScripts -Parent) 'theater/index.html'
  $src = Get-Content -LiteralPath $indexPath -Raw
  if ($src -match 'orch-speech-bubble' -and $src -match 'orchSpeechForSessions' -and $src -match 'data-orch-speech-sid') {
    Ok 'UI speech bubble helpers present'
  } else { Bad 'UI speech bubble helpers missing' }
  if ($src -match 'data-tell-steer' -and $src -match 'data-tell-nudge' -and $src -match 'Answer SA' -and $src -match 'Tell SA') {
    Ok 'UI desk Tell SA / Answer SA / Nudge present'
  } else { Bad 'UI desk controls missing' }
  if ($src -match 'dir-orch' -and $src -match 'dir-you' -and $src -match 'YOU → ORCH') {
    Ok 'UI transcript directions present'
  } else { Bad 'UI transcript directions missing' }
  $html = (Invoke-WebRequest -Uri "$base/" -UseBasicParsing -TimeoutSec 8).Content
  # Live server may still be old boot — assert disk; soft-check live
  if ($html -match 'orch-speech-bubble' -or $html -match 'ORCH desk') {
    Ok 'live HTML serves desk chrome'
  } else { Bad 'live HTML missing desk chrome' }
} catch { Bad "UI $_" }

# --- 9) Round-trip list still has our session with full transcript ---
try {
  $list = Invoke-RestMethod -Uri "$base/api/sessions" -Headers $H -TimeoutSec 8
  $sess = @($list.sessions) | Where-Object { $_.sessionId -eq $sid } | Select-Object -First 1
  if (-not $sess) { Bad 'session vanished from list' }
  else {
    $noteN = @($sess.notes).Count
    if ($noteN -ge 4) { Ok "transcript has $noteN notes" } else { Bad "transcript thin notes=$noteN" }
    $froms = @($sess.notes | ForEach-Object { $_.from } | Select-Object -Unique)
    if ($froms -contains 'operator' -and $froms -contains 'orch') {
      Ok 'transcript has both operator and orch voices'
    } else { Bad "froms=$($froms -join ',')" }
  }
} catch { Bad "list $_" }

# Cleanup — unregister test lane
try {
  $null = Invoke-RestMethod -Method DELETE -Uri "$base/api/sessions/$sid" -Headers $H -TimeoutSec 5
  Ok 'cleaned test session'
} catch {
  try {
    Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sid/heartbeat" -Headers $H -ContentType $CT -Body '{"unregister":true}' -TimeoutSec 5 | Out-Null
    Ok 'cleaned via unregister body'
  } catch { Bad "cleanup $_" }
}

if ($fail -gt 0) {
  Write-Output ("ORCH_COMMS=red fails={0}" -f $fail)
  exit 1
}
Write-Output 'ORCH_COMMS=green'
exit 0
