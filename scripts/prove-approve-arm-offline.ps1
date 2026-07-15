<#
  prove-approve-arm-offline.ps1 — SC-R05 READY bar (offline only).

  Proves Approve→Arm housing is ready WITHOUT:
    - starting theater / Show Time
    - arming a real ledger (no launch-showtime)
    - opening a browser

  Checks:
    1) node --check theater-server.mjs
    2) arm-on-approve self-test (test-arm-on-approve.ps1) + -WhatIf dry-run
    3) APPROVE-ARM-CONTRACT.md exists
    4) server source has purgeJunk* + tryAutoArm* (string scan)
    5) prints READY_CHECK=green|red

  Exit 0 only when READY_CHECK=green.
#>
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$skillRoot = Split-Path $here -Parent
$fail = 0

function Note-Ok([string]$msg) {
  Write-Host "ok: $msg" -ForegroundColor Green
}

function Note-Fail([string]$msg) {
  Write-Host "FAIL: $msg" -ForegroundColor Red
  $script:fail++
}

Write-Host '=== prove-approve-arm-offline (SC-R05) ==='
Write-Host "skillRoot=$skillRoot"
Write-Host '(no theater start, no live arm, no browser)'
Write-Host ''

# --- 1) node --check theater-server.mjs ---
$server = Join-Path $here 'theater-server.mjs'
if (-not (Test-Path -LiteralPath $server)) {
  Note-Fail "theater-server.mjs missing at $server"
} else {
  $null = & node --check $server 2>&1
  if ($LASTEXITCODE -eq 0) {
    Note-Ok 'node --check theater-server.mjs'
  } else {
    Note-Fail "node --check theater-server.mjs exit=$LASTEXITCODE"
  }
}

# --- 2a) arm-on-approve self-test suite ---
$armTest = Join-Path $here 'test-arm-on-approve.ps1'
if (-not (Test-Path -LiteralPath $armTest)) {
  Note-Fail "test-arm-on-approve.ps1 missing at $armTest"
} else {
  $null = & pwsh -NoProfile -File $armTest 2>&1
  if ($LASTEXITCODE -eq 0) {
    Note-Ok 'test-arm-on-approve.ps1 exit 0'
  } else {
    Note-Fail "test-arm-on-approve.ps1 exit=$LASTEXITCODE"
  }
}

# --- 2b) arm-on-approve -WhatIf (validate only, never launch) ---
$arm = Join-Path $here 'arm-on-approve.ps1'
$repo = 'C:\LOOPLET\ai-sidebar'
$ledger = Join-Path $repo '.claude\scratch\ledger.md'
if (-not (Test-Path -LiteralPath $arm)) {
  Note-Fail "arm-on-approve.ps1 missing at $arm"
} elseif (-not (Test-Path -LiteralPath $ledger)) {
  Note-Fail "approved ledger missing for WhatIf at $ledger"
} else {
  $whatIfOut = & pwsh -NoProfile -File $arm `
    -RepoDir $repo -Root $repo `
    -SessionId 'sess_prove_offline_r05' `
    -WhatIf 2>&1 | ForEach-Object { "$_" }
  $code = $LASTEXITCODE
  $joined = $whatIfOut -join "`n"
  $ok = ($code -eq 0) -and ($joined -match 'ARM_STATUS=whatif_ok')
  # Hard guard: offline proof must never leave an arm/launch trail
  $bad = $joined -match '(?m)^ARM_STATUS=(armed|already_armed)\b'
  if ($ok -and -not $bad) {
    Note-Ok 'arm-on-approve.ps1 -WhatIf → ARM_STATUS=whatif_ok'
  } else {
    Note-Fail "arm-on-approve -WhatIf failed (exit=$code)"
    $whatIfOut | Select-Object -Last 12 | ForEach-Object { Write-Host "  $_" }
  }
}

# --- 3) contract doc ---
$contract = Join-Path $skillRoot 'references\APPROVE-ARM-CONTRACT.md'
if (Test-Path -LiteralPath $contract) {
  $len = (Get-Item -LiteralPath $contract).Length
  if ($len -gt 200) {
    Note-Ok "APPROVE-ARM-CONTRACT.md exists ($len bytes)"
  } else {
    Note-Fail "APPROVE-ARM-CONTRACT.md too small ($len bytes)"
  }
} else {
  Note-Fail "APPROVE-ARM-CONTRACT.md missing at $contract"
}

# --- 4) server source string scan: purgeJunk + tryAutoArm ---
if (Test-Path -LiteralPath $server) {
  $src = Get-Content -LiteralPath $server -Raw
  if ($src -match 'purgeJunk') {
    Note-Ok 'theater-server.mjs contains purgeJunk'
  } else {
    Note-Fail 'theater-server.mjs missing purgeJunk (string scan)'
  }
  if ($src -match 'tryAutoArm') {
    Note-Ok 'theater-server.mjs contains tryAutoArm'
  } else {
    Note-Fail 'theater-server.mjs missing tryAutoArm (string scan)'
  }
}

# --- 5) READY_CHECK ---
Write-Host ''
if ($fail -eq 0) {
  Write-Host 'READY_CHECK=green'
  Write-Host 'assertions_failed=0'
  exit 0
}

Write-Host 'READY_CHECK=red'
Write-Host "assertions_failed=$fail"
exit 1
