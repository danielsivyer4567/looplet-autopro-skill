# final-check.ps1 — independent gate for arming this skill repo under Show Time.
# Offline green bar (no LLM). Exit 0 = green; non-zero = red.
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Split-Path $here -Parent
Set-Location -LiteralPath $root

$failed = 0
function Run-Step([string]$name, [scriptblock]$block) {
  Write-Host ">> $name"
  try {
    & $block
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "exit $LASTEXITCODE" }
    Write-Host "OK  $name"
  } catch {
    Write-Host "FAIL $name : $_"
    $script:failed++
  }
}

Run-Step 'node --check theater-server' {
  node --check (Join-Path $here 'theater-server.mjs')
}
Run-Step 'test-lane-honesty' {
  if (Test-Path (Join-Path $here 'test-lane-honesty.mjs')) {
    node (Join-Path $here 'test-lane-honesty.mjs')
  }
}
Run-Step 'test-join-popup' {
  if (Test-Path (Join-Path $here 'test-join-popup.mjs')) {
    node (Join-Path $here 'test-join-popup.mjs')
  }
}
Run-Step 'test-map-select-nudge' {
  if (Test-Path (Join-Path $here 'test-map-select-nudge.mjs')) {
    node (Join-Path $here 'test-map-select-nudge.mjs')
  }
}

if ($failed -gt 0) {
  Write-Host "FINAL_CHECK_STATUS=red failed=$failed"
  exit 1
}
Write-Host 'FINAL_CHECK_STATUS=green'
exit 0
