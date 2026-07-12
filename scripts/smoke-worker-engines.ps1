<#
  smoke-worker-engines.ps1 — cheap live smoke (no LLM tokens).

  Resolves each engine, runs --version, prints matrix. Exit 0 if at least one
  agentic engine (claude/codex/gemini/grok) is OK; exit 1 if none.
#>
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'worker-engines.ps1')

Write-Output '==== smoke-worker-engines (version only, no LLM) ===='
$agentOk = 0
$all = Get-AllEngineResolutions
foreach ($r in $all) {
  $v = Test-EngineVersion -Resolution $r
  $flag = if ($v.Ok) { 'OK ' } else { 'FAIL' }
  $detail = if ($v.Ok) { $v.Version } else { $(if ($v.Error) { $v.Error } else { "exit $($v.ExitCode)" }) }
  Write-Output ("  [{0}] {1,-7} {2}ms  {3}" -f $flag, $v.Engine, $v.Ms, $detail)
  if ($v.Ok -and $r.Agentic) { $agentOk++ }
}

try {
  $auto = Resolve-AutoproEngine -Requested 'auto' -Quiet
  Write-Output ("AUTO → {0}  ({1})" -f $auto.Engine, $auto.Display)
} catch {
  Write-Output ("AUTO FAIL: {0}" -f $_.Exception.Message)
}

Write-Output ''
if ($agentOk -gt 0) {
  Write-Output ("PASS smoke-worker-engines agentic_ok={0}" -f $agentOk)
  exit 0
}
Write-Output 'FAIL smoke-worker-engines: no agentic CLI responded to --version'
exit 1
