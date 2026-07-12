<# Show Time v2 tests — ensure server, REST checks, leave server running. #>
$ErrorActionPreference = 'Stop'
$Register = Join-Path $PSScriptRoot 'theater-register.ps1'
$StateRoot = Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater'
$SessionDir = Join-Path $StateRoot 'sessions'
$HandoverDir = Join-Path $StateRoot 'handovers'
$Outbox = Join-Path $StateRoot 'handover-outbox.md'
$outboxExisted = Test-Path -LiteralPath $Outbox
$outboxBefore = if ($outboxExisted) { Get-Content -LiteralPath $Outbox -Raw } else { $null }
$failed = 0
function Ok($m) { Write-Output "PASS  $m" }
function Bad($m) { Write-Output "FAIL  $m"; $script:failed++ }

Write-Output '==== Show Time v2 tests ===='

# ---- merge gate (pure; no server) -------------------------------------------
# The predicate that decides whether an epic merges. Exercised against the shape
# `claude -p --output-format json` actually emits, not against pretty text.
. (Join-Path $PSScriptRoot 'showtime-final-check.ps1')

# Payloads chosen so a broken gate cannot pass by accident. Deliberately NO
# "check green" / "epic complete" phrasing in the marker cases — the marker must
# be what decides, not prose that happens to sit after a real space.
$jsonGreen = '{"type":"result","is_error":false,"result":"Ran typecheck, lint, build and tests.\nFINAL_CHECK_STATUS=green\nCommits: a1b2c3d, e4f5a6b."}'
$jsonRed = '{"type":"result","is_error":false,"result":"Typecheck broke.\nFINAL_CHECK_STATUS=red\nsrc/x.ts(4): TS2345"}'
$plainGreen = "Ran checks.`nFINAL_CHECK_STATUS=green`nCommits: a1b2c3d."
# green marker precedes red marker: a "first match wins" gate would merge a red epic
$correctedRed = '{"type":"result","result":"FINAL_CHECK_STATUS=green\nCorrection: FINAL_CHECK_STATUS=red\n2 tests broke."}'
# no marker at all: only the decoded prose can rescue it (\b needs the real newline)
$noMarker = '{"type":"result","result":"Ran the check skill.\nEpic complete."}'
function G([string]$text, [int]$exit = 0) { Test-FinalCheckGreen ([pscustomobject]@{ ExitCode = $exit; Text = $text }) }

$decoded = ConvertFrom-ClaudeOutput $jsonGreen
if ($decoded -match '(?m)^FINAL_CHECK_STATUS=green$') { Ok 'gate: json result decodes to real newlines' } else { Bad 'gate: ConvertFrom-ClaudeOutput did not decode' }
if (G $jsonGreen) { Ok 'gate: json green -> merge' } else { Bad 'gate: json green must merge (JSON-escaped \n defeats ^ anchor)' }
if (-not (G $jsonRed)) { Ok 'gate: json red -> block' } else { Bad 'gate: json red must block' }
if (G $plainGreen) { Ok 'gate: plain-text green -> merge' } else { Bad 'gate: plain green must merge' }
if (-not (G $jsonGreen 1)) { Ok 'gate: nonzero exit -> block' } else { Bad 'gate: nonzero exit must block' }
if (-not (G $correctedRed)) { Ok 'gate: red after green -> block (red wins)' } else { Bad 'gate: red must win over an earlier green marker' }
if (G $noMarker) { Ok 'gate: marker absent, prose green -> merge' } else { Bad 'gate: prose fallback must survive JSON escaping' }
if (-not (Test-FinalCheckGreen $null)) { Ok 'gate: null result -> block' } else { Bad 'gate: null must block' }

# ---- worktree finalizer (pure; temp repo, no server) -------------------------
$WorktreePs1 = Join-Path $PSScriptRoot 'showtime-worktree.ps1'
$CommitPs1 = Join-Path $PSScriptRoot 'showtime-scoped-commit.ps1'
$fxRoot = Join-Path $env:TEMP ('showtime-fx-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fxRepo = Join-Path $fxRoot 'repo'
try {
  New-Item -ItemType Directory -Force -Path $fxRepo | Out-Null
  & git init -q -b main $fxRepo 2>&1 | Out-Null
  & git -C $fxRepo config user.email 'showtime@test.local' | Out-Null
  & git -C $fxRepo config user.name 'Show Time Test' | Out-Null
  & git -C $fxRepo config commit.gpgsign false | Out-Null
  'seed' | Set-Content -LiteralPath (Join-Path $fxRepo 'seed.txt') -Encoding utf8
  & git -C $fxRepo add -A 2>&1 | Out-Null
  & git -C $fxRepo commit -q -m 'seed' 2>&1 | Out-Null
  # Operator sits on `work`; the epic merges into `main`. finish must hand `work` back.
  & git -C $fxRepo checkout -q -b work 2>&1 | Out-Null

  $fxSession = 'sess_fx' + [guid]::NewGuid().ToString('N').Substring(0, 6)
  $createOut = & pwsh -NoProfile -File $WorktreePs1 -Action create -RepoDir $fxRepo -SessionId $fxSession -MergeTarget main -MainBranch main 2>&1
  $wtPath = ''
  foreach ($line in $createOut) { if ("$line" -match '^WORKTREE_PATH=(.+)$') { $wtPath = $Matches[1].Trim() } }
  if ($wtPath -and (Test-Path -LiteralPath $wtPath)) { Ok 'finalizer: worktree created' } else { Bad "finalizer: worktree create ($createOut)" }

  'slice work' | Set-Content -LiteralPath (Join-Path $wtPath 'slice.txt') -Encoding utf8
  $commitOut = ((& pwsh -NoProfile -File $CommitPs1 -WorktreeDir $wtPath -SessionId $fxSession -Message 'fx slice' 2>&1) | Out-String)
  if ($commitOut -match 'STATUS=committed') { Ok 'finalizer: scoped commit' } else { Bad "finalizer: scoped commit ($commitOut)" }

  $tracked = (& git -C $wtPath ls-files '.showtime-worktree.json') | Out-String
  if (-not $tracked.Trim()) { Ok 'finalizer: marker not committed' } else { Bad 'finalizer: .showtime-worktree.json leaked into the commit' }

  $finishOut = ((& pwsh -NoProfile -File $WorktreePs1 -Action finish -RepoDir $fxRepo -SessionId $fxSession -MergeTarget main -MainBranch main 2>&1) | Out-String)
  if ($finishOut -match 'MERGE_COMMIT=\S+') { Ok 'finalizer: emits MERGE_COMMIT' } else { Bad "finalizer: no MERGE_COMMIT ($finishOut)" }
  if ($finishOut -match 'STATUS=merged-and-pruned') { Ok 'finalizer: merged and pruned' } else { Bad "finalizer: status ($finishOut)" }

  $after = ((& git -C $fxRepo rev-parse --abbrev-ref HEAD) | Out-String).Trim()
  if ($after -eq 'work') { Ok 'finalizer: primary branch restored to work' } else { Bad "finalizer: primary left on '$after', expected 'work'" }

  $mainFiles = @(& git -C $fxRepo ls-tree -r --name-only main)
  if ($mainFiles -contains 'slice.txt') { Ok 'finalizer: slice landed on main' } else { Bad 'finalizer: slice missing from main' }
  if ($mainFiles -notcontains '.showtime-worktree.json') { Ok 'finalizer: no marker on main' } else { Bad 'finalizer: marker merged into main' }
  if (-not (Test-Path -LiteralPath $wtPath)) { Ok 'finalizer: worktree removed' } else { Bad 'finalizer: worktree still present' }
} catch {
  Bad "finalizer $_"
} finally {
  Remove-Item -LiteralPath $fxRoot -Recurse -Force -ErrorAction SilentlyContinue
}

try {
  $base = (& pwsh -NoProfile -File $Register -Action ensure 2>&1 | Where-Object { $_ -match 'http://127\.0\.0\.1:\d+' } | Select-Object -Last 1)
  if (-not $base) {
    $p = (Get-Content (Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater\server.port') -Raw).Trim()
    $base = "http://127.0.0.1:$p"
  }
  $base = "$base".Trim()
  Ok "server $base"
  $TokenFile = Join-Path $StateRoot 'server.token'
  $Tok = if (Test-Path -LiteralPath $TokenFile) { (Get-Content -LiteralPath $TokenFile -Raw).Trim() } else { '' }
  if ($Tok) { Ok 'token file present' } else { Bad 'no server.token written at boot' }
  $AuthH = @{ 'X-Showtime-Token' = $Tok }
} catch {
  Bad "ensure $_"
  exit 1
}

try {
  $h = Invoke-RestMethod "$base/api/health" -Headers $AuthH -TimeoutSec 5
  if ($h.ok -and $h.product -eq 'Looplet' -and $h.version -ge 2) { Ok "health v$($h.version)" } else { Bad 'health payload' }
} catch { Bad "health $_"; exit 1 }

$sa = 'v2a_' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$sb = 'v2b_' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$sd = 'v2d_' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$stale = 'v2old_' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$complete = 'v2done_' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$tmp = Join-Path $env:TEMP "showtime-test-$sa.md"
@'
# Ledger: test
Approved: yes @ 2026-07-10
## SC-01 — Alpha  [done]
## SC-02 — Beta  [in-progress]
## SC-03 — Gamma  [pending]
## SD-P2 — Delta  [pending]
## H1 — Handover  [done]
## P0-safe — Pause point  [blocked]
'@ | Set-Content -LiteralPath $tmp -Encoding utf8

# ---- Join gate: no board entry without sessionId + repo name + branch ----
try {
  $code = 0
  try {
    Invoke-RestMethod -Method POST -Uri "$base/api/sessions" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body (@{
      repoId = 'Looplet'; branch = 'main'; status = 'running'
    } | ConvertTo-Json) | Out-Null
  } catch { $code = [int]$_.Exception.Response.StatusCode }
  if ($code -eq 400) { Ok 'join gate: no sessionId -> 400' } else { Bad "join gate sessionId gave $code" }
} catch { Bad "join gate sessionId $_" }

try {
  $code = 0
  try {
    Invoke-RestMethod -Method POST -Uri "$base/api/sessions" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body (@{
      sessionId = 'v2bad1'; repoId = 'repo'; branch = 'main'; status = 'running'
    } | ConvertTo-Json) | Out-Null
  } catch { $code = [int]$_.Exception.Response.StatusCode }
  if ($code -eq 400) { Ok 'join gate: fake repo -> 400' } else { Bad "join gate repo gave $code" }
} catch { Bad "join gate repo $_" }

try {
  $code = 0
  try {
    Invoke-RestMethod -Method POST -Uri "$base/api/sessions" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body (@{
      sessionId = 'v2bad2'; repoId = 'Looplet'; status = 'running'
    } | ConvertTo-Json) | Out-Null
  } catch { $code = [int]$_.Exception.Response.StatusCode }
  if ($code -eq 400) { Ok 'join gate: no branch -> 400' } else { Bad "join gate branch gave $code" }
} catch { Bad "join gate branch $_" }

try {
  $r = Invoke-RestMethod -Method POST -Uri "$base/api/sessions" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body (@{
    sessionId = $sa; repoId = 'repo-a'; branch = 'test/branch-a'; status = 'running'; ledgerPath = $tmp; ledgerHash = 'hash-a'; ledgerTitle = 'test'
    stats = @{
      measured = $true
      tokens = @{ input = 1000; output = 500; total = 1500; monolithEst = 4000; saved = 2500; savePct = 0.625 }
      speed = @{ tokPerSec = 40; tokPerMin = 2400 }
      code = @{ filesCreated = 2; linesAdded = 100; linesPerTokMin = 0.04; filesPerTokMin = 0.001 }
    }
  } | ConvertTo-Json -Depth 6)
  if ($r.session.stats.tokens.saved -eq 2500) { Ok 'register stats' } else { Bad 'stats' }
  if ($r.session.counts.done -eq 2 -and $r.session.counts.pending -eq 2 -and $r.session.counts.inProgress -eq 1 -and $r.session.counts.blocked -eq 1) {
    Ok 'ledger parser supports SC/SD/H/P ids'
  } else {
    Bad "ledger parser counts done=$($r.session.counts.done) pending=$($r.session.counts.pending) inProgress=$($r.session.counts.inProgress) blocked=$($r.session.counts.blocked)"
  }
} catch { Bad "register A $_" }

try {
  $null = Invoke-RestMethod -Method POST -Uri "$base/api/sessions" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body (@{
    sessionId = $sb; repoId = 'repo-b'; branch = 'test/branch-b'; status = 'running'
    todo = @(@{ id = 'SC-01'; text = 'One'; state = 'pending' })
  } | ConvertTo-Json -Depth 5)
  Ok 'register B multi-chat'
} catch { Bad "register B $_" }

try {
  $list = Invoke-RestMethod "$base/api/sessions" -Headers $AuthH -TimeoutSec 5
  if ($list.mission.total -ge 6) { Ok "mission total=$($list.mission.total)" } else { Bad 'mission' }
} catch { Bad "mission $_" }

try {
  $null = Invoke-RestMethod -Method POST -Uri "$base/api/sessions" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body (@{
    sessionId = $sd; repoId = 'repo-old-active'; branch = 'test/old-active'; status = 'running'; ledgerHash = 'old-hash'; ledgerTitle = 'old ledger'; pid = $PID
    todo = @(@{ id = 'SC-99'; text = 'Old active'; state = 'pending' })
  } | ConvertTo-Json -Depth 5)
  $pre = Invoke-RestMethod -Method POST -Uri "$base/api/preflight" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body (@{
    ledgerHash = 'new-hash'; ledgerTitle = 'new ledger'; staleAfterMs = 3600000
  } | ConvertTo-Json)
  if (@($pre.kept) | Where-Object { $_.sessionId -eq $sd -and $_.why -eq 'different-ledger-active' }) {
    Ok 'preflight keeps active different-ledger session'
  } else {
    Bad 'preflight kept active session'
  }
  Invoke-RestMethod -Method DELETE -Uri "$base/api/sessions/$sd" -Headers $AuthH -TimeoutSec 5 | Out-Null
} catch { Bad "preflight keep $_" }

try {
  $null = Invoke-RestMethod -Method POST -Uri "$base/api/sessions" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body (@{
    sessionId = $stale; repoId = 'repo-old-stale'; branch = 'test/old-stale'; status = 'running'; ledgerHash = 'old-hash'; ledgerTitle = 'old ledger'; pid = 0
    todo = @(@{ id = 'SC-98'; text = 'Old stale'; state = 'pending' })
  } | ConvertTo-Json -Depth 5)
  $staleFile = Join-Path $SessionDir "$stale.json"
  $staleJson = Get-Content -LiteralPath $staleFile -Raw | ConvertFrom-Json
  $staleJson.updatedAt = (Get-Date).AddMinutes(-10).ToString('o')
  $staleJson | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $staleFile -Encoding utf8
  $pre = Invoke-RestMethod -Method POST -Uri "$base/api/preflight" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body (@{
    ledgerHash = 'new-hash'; ledgerTitle = 'new ledger'; staleAfterMs = 1000
  } | ConvertTo-Json)
  if (@($pre.wiped) | Where-Object { $_.sessionId -eq $stale -and $_.why -eq 'stale-different-ledger' }) {
    Ok 'preflight wipes stale different-ledger session'
  } else {
    Bad 'preflight stale wipe'
  }
  if ($pre.handoversFlushed -ge 1) { Ok 'preflight flushes stale handover' } else { Bad 'preflight handover flush' }
} catch { Bad "preflight stale $_" }

try {
  $repoHandover = Join-Path $env:TEMP "showtime-handover-$complete.md"
  'repo handover body' | Set-Content -LiteralPath $repoHandover -Encoding utf8
  $null = Invoke-RestMethod -Method POST -Uri "$base/api/sessions" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body (@{
    sessionId = $complete; repoId = 'repo-complete'; branch = 'test/complete'; status = 'running'; ledgerHash = 'hash-complete'; ledgerTitle = 'complete ledger'; pid = $PID; handoverPath = $repoHandover
    todo = @(@{ id = 'SC-77'; text = 'Done'; state = 'done' })
  } | ConvertTo-Json -Depth 5)
  $null = Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$complete/heartbeat" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body (@{
    status = 'complete'; handoverPath = $repoHandover; handoverText = 'FINAL HANDOVER FROM TEST'
  } | ConvertTo-Json)
  $hos = Invoke-RestMethod -Uri "$base/api/handovers" -Headers $AuthH -TimeoutSec 5
  $delivered = @($hos.handovers) | Where-Object { $_.sessionId -eq $complete -and $_.status -eq 'delivered' -and $_.text -match 'FINAL HANDOVER FROM TEST' }
  if ($delivered) { Ok 'complete heartbeat delivers handover text' } else { Bad 'complete handover delivery' }
  Remove-Item -LiteralPath $repoHandover -Force -ErrorAction SilentlyContinue
} catch { Bad "complete handover $_" }

try {
  $q = Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sa/questions" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body '{"text":"Need approval?"}'
  if ($q.session.needsInput) { Ok 'needs_input question' } else { Bad 'needs_input' }
  $qid = $q.session.questions[0].id
  $null = Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sa/questions" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body (@{ questionId = $qid; answer = 'Yes' } | ConvertTo-Json)
  Ok 'answer question'
} catch { Bad "questions $_" }

try {
  $null = Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sa/steers" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body '{"text":"Prefer dry-run","target":"SC-02"}'
  $cs = Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sa/consume-steers" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body '{}'
  if ($cs.steers.Count -ge 1) { Ok 'steer + consume' } else { Bad 'steer' }
} catch { Bad "steer $_" }

try {
  $n = Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sa/nudge" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body '{"listenSec":30}'
  if ($n.nudge.status -eq 'listening' -and $n.nudge.listenUntil) { Ok 'nudge listen window' } else { Bad 'nudge listen' }
  $null = Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sa/heartbeat" -ContentType 'application/json' -Headers $AuthH -TimeoutSec 5 -Body (@{
    status = 'running'; progress = $true; pid = $PID
  } | ConvertTo-Json)
  $list2 = Invoke-RestMethod "$base/api/sessions" -Headers $AuthH -TimeoutSec 5
  $saSess = @($list2.sessions) | Where-Object { $_.sessionId -eq $sa } | Select-Object -First 1
  if ($saSess.nudge.status -eq 'acked') { Ok 'nudge acked on progress heartbeat' } else { Bad "nudge ack status=$($saSess.nudge.status)" }
} catch { Bad "nudge $_" }

try {
  $html = (Invoke-WebRequest -Uri "$base/" -UseBasicParsing -TimeoutSec 5).Content
  if ($html -match 'btn-nudge' -and $html -match 'orch-click-here|CLICK HERE|data-nudge') {
    Ok 'UI nudge / escalate markers'
  } else { Bad 'UI nudge markers' }
} catch { Bad "UI nudge $_" }

try {
  $html = (Invoke-WebRequest -Uri "$base/" -UseBasicParsing -TimeoutSec 5).Content
  if ($html -match 'MISSION STATUS' -and $html -match 'SENTINEL' -and $html -match 'BOOKMARKS' -and $html -match 'Looplet' -and $html -notmatch 'Daniel') {
    Ok 'UI markers (mission/sentinel/bookmarks)'
  } else { Bad 'UI markers' }
  if ($html -match 'dock-resizer' -and $html -match 'looplet-logo' -and $html -match 'LOOP' -and $html -match 'dock-toggle') {
    Ok 'Looplet dock chrome'
  } else { Bad 'footer/dock' }
  if ($html -match 'h-pac' -and $html -match 'translate3d' -and $html -match 'hide-left') {
    Ok 'pac + canvas + rail markers'
  } else { Bad 'pac/canvas markers' }
  $logo = Invoke-WebRequest -Uri "$base/assets/looplet-logo.png" -UseBasicParsing -TimeoutSec 5
  if ($logo.StatusCode -eq 200 -and $logo.RawContentLength -gt 100) { Ok 'logo asset 200' } else { Bad 'logo asset' }
} catch { Bad "UI $_" }

# ---- S1: the wall — no token, no board ------------------------------------
try {
  $code = 0
  try { Invoke-RestMethod "$base/api/sessions" -TimeoutSec 5 | Out-Null } catch { $code = [int]$_.Exception.Response.StatusCode }
  if ($code -eq 401) { Ok 'S1: GET sessions without token -> 401' } else { Bad "S1: no-token GET gave $code" }
  $code = 0
  try {
    Invoke-RestMethod -Method POST -Uri "$base/api/sessions/$sa/steers" -ContentType 'application/json' -TimeoutSec 5 -Body '{"text":"evil steer"}' | Out-Null
  } catch { $code = [int]$_.Exception.Response.StatusCode }
  if ($code -eq 401) { Ok 'S1: steer without token -> 401' } else { Bad "S1: no-token steer gave $code" }
  $code = 0
  try {
    Invoke-WebRequest -Method POST -Uri "$base/api/sessions/$sa/steers" -Headers $AuthH -ContentType 'text/plain' -TimeoutSec 5 -Body '{"text":"smuggled"}' -UseBasicParsing | Out-Null
  } catch { $code = [int]$_.Exception.Response.StatusCode }
  if ($code -eq 415) { Ok 'S1: text/plain body -> 415' } else { Bad "S1: text/plain gave $code" }
  $code = 0
  try { Invoke-RestMethod "$base/api/preflight" -Headers $AuthH -TimeoutSec 5 | Out-Null } catch { $code = [int]$_.Exception.Response.StatusCode }
  if ($code -eq 401 -or $code -eq 404) { Ok "S1: GET preflight rejected ($code)" } else { Bad "S1: GET preflight gave $code" }
  $r = Invoke-WebRequest "$base/api/health" -TimeoutSec 5 -UseBasicParsing
  if (-not $r.Headers['Access-Control-Allow-Origin']) { Ok 'S1: no ACAO header anywhere' } else { Bad 'S1: ACAO still present' }
  $html = (Invoke-WebRequest -Uri "$base/" -UseBasicParsing -TimeoutSec 5).Content
  if ($html -match '__SHOWTIME_TOKEN__') { Ok 'S1: token injected into board page' } else { Bad 'S1: board page has no token' }
} catch { Bad "S1 wall $_" }

try {
  Invoke-RestMethod -Method DELETE -Uri "$base/api/sessions/$sa" -Headers $AuthH -TimeoutSec 5 | Out-Null
  Invoke-RestMethod -Method DELETE -Uri "$base/api/sessions/$sb" -Headers $AuthH -TimeoutSec 5 | Out-Null
  Invoke-RestMethod -Method DELETE -Uri "$base/api/sessions/$sd" -Headers $AuthH -TimeoutSec 5 | Out-Null
  Invoke-RestMethod -Method DELETE -Uri "$base/api/sessions/$complete" -Headers $AuthH -TimeoutSec 5 | Out-Null
  Ok 'cleanup test sessions'
} catch { Bad "cleanup $_" }

Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $HandoverDir) {
  Get-ChildItem -LiteralPath $HandoverDir -Filter '*.json' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'v2(old|done)' } |
    Remove-Item -Force -ErrorAction SilentlyContinue
}
if ($outboxExisted) {
  Set-Content -LiteralPath $Outbox -Value $outboxBefore -Encoding utf8
} else {
  Remove-Item -LiteralPath $Outbox -Force -ErrorAction SilentlyContinue
}
Write-Output "==== done failed=$failed ===="
if ($failed -gt 0) { exit 1 }
exit 0
