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

# Argv shape checks (no network) — catch headless regressions
Write-Output 'ARGV_SHAPES'
foreach ($e in @('claude', 'codex', 'gemini', 'grok')) {
  $res = Resolve-EngineBinary -Engine $e
  if (-not $res.Available) { Write-Output ("  skip {0}" -f $e); continue }
  $a = Build-WorkerArgumentList -Resolution $res -Prompt 'ping' -WorkDir 'C:\tmp' -SkipPermissions
  $j = $a -join ' '
  $ok = $true
  if ($e -eq 'grok' -and $j -notmatch '-p|single') { $ok = $false; Write-Output '  FAIL grok missing -p' }
  if ($e -eq 'codex' -and $j -notmatch 'exec') { $ok = $false; Write-Output '  FAIL codex missing exec' }
  if ($e -eq 'gemini' -and $j -match '(^|\s)-y(\s|$)') { $ok = $false; Write-Output '  FAIL gemini still uses -y (admin often blocks)' }
  if ($ok) { Write-Output ("  ok {0}: {1}" -f $e, $(if ($j.Length -gt 90) { $j.Substring(0, 90) + '…' } else { $j })) }
}

Write-Output ''
if ($agentOk -gt 0) {
  Write-Output ("PASS smoke-worker-engines agentic_ok={0}" -f $agentOk)
  exit 0
}
Write-Output 'FAIL smoke-worker-engines: no agentic CLI responded to --version'
exit 1
