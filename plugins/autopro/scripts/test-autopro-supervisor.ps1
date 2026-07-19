#Requires -Version 7.0
<# Offline green bar for supervisor v1 (no LLM, no board). #>
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
. (Join-Path $here 'autopro-supervisor.ps1')

$fail = 0
function Assert-True([bool]$Cond, [string]$Msg) {
  if (-not $Cond) {
    Write-Output ("FAIL {0}" -f $Msg)
    $script:fail++
  } else {
    Write-Output ("ok   {0}" -f $Msg)
  }
}

Assert-True (Should-KickstartRetry -EarlyExit $true -ExitCode 1 -Attempt 1 -MaxAttempts 2) 'retry early non-zero'
Assert-True (-not (Should-KickstartRetry -EarlyExit $true -ExitCode 0 -Attempt 1 -MaxAttempts 2)) 'no retry early zero'
Assert-True (-not (Should-KickstartRetry -EarlyExit $false -ExitCode 1 -Attempt 1 -MaxAttempts 2)) 'no retry while alive'
Assert-True (-not (Should-KickstartRetry -EarlyExit $true -ExitCode 1 -Attempt 2 -MaxAttempts 2)) 'cap attempts'

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("autopro-sup-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  $r = Send-AutoproSupervisorAlert -ScratchDir $tmp -Kind 'test-blocked' `
    -Summary 'offline test' -SessionId 'sess_offline' -RepoDir 'C:\repos\demo' -Detail 'detail'
  Assert-True (Test-Path -LiteralPath $r.NeedsYouMd) 'AUTOPRO-NEEDS-YOU.md'
  Assert-True (Test-Path -LiteralPath (Join-Path $tmp 'autopro-supervisor-alert.json')) 'alert json'
  Assert-True (Test-Path -LiteralPath (Join-Path $tmp 'autopro-chat-inbox.jsonl')) 'chat inbox jsonl'
  $body = Get-Content -LiteralPath $r.NeedsYouMd -Raw
  Assert-True ($body -match 'AUTOPRO NEEDS YOU') 'needs-you title'
  Assert-True ($body -match 'offline test') 'needs-you summary'
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# Runner must dot-source supervisor
$runner = Get-Content -LiteralPath (Join-Path $here 'autopro-runner.ps1') -Raw
Assert-True ($runner -match 'autopro-supervisor\.ps1') 'runner sources supervisor'
Assert-True ($runner -match 'KICKSTART_RETRY') 'runner has kickstart retry'
Assert-True ($runner -match 'Invoke-SupervisorNeedsYou') 'runner has needs-you helper'
Assert-True ($runner -match 'Worker pid') 'runner heartbeats worker pid'
Assert-True ($runner -match 'runnerPid') 'runner heartbeats runnerPid field'
Assert-True ($runner -match 'workerPid') 'runner heartbeats workerPid field'
Assert-True ($runner -match 'CurrentWorkerPid') 'runner tracks CurrentWorkerPid'

# Watch script exists + sources supervisor
$watchPs1 = Join-Path $here 'autopro-watch.ps1'
Assert-True (Test-Path -LiteralPath $watchPs1) 'autopro-watch.ps1 present'
$watchSrc = Get-Content -LiteralPath $watchPs1 -Raw
Assert-True ($watchSrc -match 'autopro-supervisor\.ps1') 'watch sources supervisor'
Assert-True ($watchSrc -match 'autopro-chat-inbox') 'watch polls chat inbox'
Assert-True ($watchSrc -match 'AUTOPRO-NEEDS-YOU') 'watch polls needs-you'
$launch = Get-Content -LiteralPath (Join-Path $here 'launch-showtime.ps1') -Raw
Assert-True ($launch -match 'autopro-watch\.ps1') 'launch integrates watch'
Assert-True ($launch -match 'NoWatch') 'launch has -NoWatch escape'

# Inventory + still-todo + red block
$sampleLedger = @'
# Ledger: Demo
Approved: yes
## SC-01 — Alpha  [done]
## SC-02 — Beta  [pending]
## SC-03 — Gamma  [blocked]
## Out of scope (next epic)
- Supabase RLS for tenant isolation
- Edge function deploy for webhooks
## After 100% [done]
1. ship-epic / PR
2. production deploy
'@
$inv = Get-LedgerSliceInventory -LedgerText $sampleLedger
Assert-True ($inv.Done.Count -eq 1) 'inventory done=1'
Assert-True ($inv.Pending.Count -eq 1) 'inventory pending=1'
Assert-True ($inv.Blocked.Count -eq 1) 'inventory blocked=1'
Assert-True ($inv.OutOfScope.Count -ge 1) 'out of scope parsed'
Assert-True ($inv.AfterDone.Count -ge 1) 'after 100% parsed'
$hints = Get-WiringStillTodoHints -LedgerText $sampleLedger -Notes 'need MINIMAX and wrangler'
Assert-True (($hints | Where-Object { $_ -match 'Supabase' }).Count -ge 1) 'hint supabase'
Assert-True (($hints | Where-Object { $_ -match 'Edge' }).Count -ge 1) 'hint edge'
Assert-True (($hints | Where-Object { $_ -match 'Env|secret|MINIMAX' }).Count -ge 1) 'hint secrets'
$red = Format-StillTodoRedHtml -Items @('Deploy edge functions', 'Set Supabase keys') -Outcome 'complete'
Assert-True ($red -match 'color:#c62828') 'red styling'
Assert-True ($red -match 'STILL TO DO') 'still to do heading'
Assert-True ($red -match 'Deploy edge functions') 'still to do item'

if ($fail -gt 0) {
  Write-Output ("SUPERVISOR_CHECK=red fails={0}" -f $fail)
  exit 1
}
Write-Output 'SUPERVISOR_CHECK=green'
exit 0
