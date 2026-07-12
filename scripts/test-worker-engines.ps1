<#
  test-worker-engines.ps1 — offline unit tests for multi-engine resolution.
  No network, no real LLM calls. Exit 0 on pass.
#>
$ErrorActionPreference = 'Stop'
$SkillScripts = $PSScriptRoot
. (Join-Path $SkillScripts 'worker-engines.ps1')

$failed = 0
function Assert-True($cond, $msg) {
  if (-not $cond) {
    Write-Output "FAIL: $msg"
    $script:failed++
  } else {
    Write-Output "ok: $msg"
  }
}

Write-Output '==== test-worker-engines ===='

# Known engines list
Assert-True ($script:AutoproKnownEngines -contains 'claude') 'knows claude'
Assert-True ($script:AutoproKnownEngines -contains 'codex') 'knows codex'
Assert-True ($script:AutoproKnownEngines -contains 'gemini') 'knows gemini'
Assert-True ($script:AutoproKnownEngines -contains 'grok') 'knows grok'
Assert-True ($script:AutoproKnownEngines -contains 'ollama') 'knows ollama'
Assert-True ($script:AutoproAutoOrderDefault -notcontains 'ollama') 'auto order excludes ollama'

# Resolve each engine (availability depends on machine — just must not throw)
foreach ($e in $script:AutoproKnownEngines) {
  $r = Resolve-EngineBinary -Engine $e
  Assert-True ($null -ne $r) "Resolve-EngineBinary $e returns object"
  Assert-True ($r.Engine -eq $e) "Resolve-EngineBinary $e.Engine"
  Assert-True ($r.PSObject.Properties.Name -contains 'Available') "Resolve-EngineBinary $e has Available"
}

$all = Get-AllEngineResolutions
Assert-True ($all.Count -eq 5) 'Get-AllEngineResolutions count=5'
$report = Format-EnginePreflightReport -Resolutions $all
Assert-True ($report -match 'ENGINE_PREFLIGHT') 'preflight report header'

# Auto resolve must pick first available agentic engine
try {
  $auto = Resolve-AutoproEngine -Requested 'auto' -Quiet
  Assert-True ($auto.Available) 'auto resolves available engine'
  Assert-True ($auto.Engine -ne 'ollama') 'auto never picks ollama'
  Write-Output ("  auto → {0}" -f $auto.Engine)
} catch {
  # Only OK if truly nothing installed
  Write-Output ("  auto threw (ok if no engines): {0}" -f $_.Exception.Message)
}

# Ollama requires AllowOllama
$ollamaThrew = $false
try {
  $null = Resolve-AutoproEngine -Requested 'ollama' -Quiet
} catch {
  $ollamaThrew = $true
}
$ollamaRes = Resolve-EngineBinary -Engine ollama
if ($ollamaRes.Available) {
  Assert-True $ollamaThrew 'ollama without -AllowOllama throws when installed'
  $with = Resolve-AutoproEngine -Requested 'ollama' -AllowOllama -Quiet
  Assert-True ($with.Engine -eq 'ollama') 'ollama with -AllowOllama works'
} else {
  Write-Output 'ok: ollama not installed — skip allow gate'
}

# Argv builders for each available engine
$fakePrompt = 'work on next slice; mark done when criteria met'
foreach ($e in @('claude', 'codex', 'gemini', 'grok', 'ollama')) {
  $res = Resolve-EngineBinary -Engine $e
  if (-not $res.Available) {
    Write-Output "skip argv: $e not available"
    continue
  }
  $args = Build-WorkerArgumentList -Resolution $res -Prompt $fakePrompt -ModelName 'test-model' `
    -WorkDir 'C:\tmp\repo' -SkipPermissions
  Assert-True ($args.Count -ge 1) "argv $e non-empty"
  $joined = $args -join ' '
  switch ($e) {
    'claude' {
      Assert-True ($joined -match '--dangerously-skip-permissions') 'claude skip-permissions'
      Assert-True ($joined -match '-p') 'claude -p'
      Assert-True ($joined -match 'test-model') 'claude model'
    }
    'codex' {
      Assert-True ($joined -match 'exec') 'codex exec'
      Assert-True ($joined -match '--dangerously-bypass-approvals-and-sandbox') 'codex bypass'
      Assert-True ($joined -match '-m') 'codex model flag'
    }
    'gemini' {
      Assert-True ($joined -match 'auto_edit' -or $joined -match '-y') 'gemini auto_edit/yolo'
      Assert-True ($joined -match '-p') 'gemini -p'
    }
    'grok' {
      Assert-True ($joined -match '--always-approve') 'grok always-approve'
      Assert-True ($joined -match 'bypassPermissions') 'grok bypass'
      Assert-True ($joined -match '-p' -or $joined -match '--single') 'grok -p headless'
      Assert-True ($joined -match '--max-turns') 'grok max-turns'
    }
    'ollama' {
      Assert-True ($joined -match 'run') 'ollama run'
    }
  }
}

# Usage parser: Claude-like JSON line
$sample = @'
{"type":"result","model":"claude-sonnet-4","usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":1,"cache_read_input_tokens":2},"total_cost_usd":0.01}
'@
$u = Parse-WorkerUsageFromText -Text $sample -Engine claude
Assert-True ($u.model -eq 'claude-sonnet-4') 'parse model'
Assert-True ($u.input -eq 10) 'parse input'
Assert-True ($u.output -eq 20) 'parse output'
Assert-True ($u.measured) 'parse measured'
Assert-True ([math]::Abs($u.costUsd - 0.01) -lt 0.0001) 'parse cost'

# Unknown engine throws
$threw = $false
try { $null = Resolve-AutoproEngine -Requested 'chatgpt-web' -Quiet } catch { $threw = $true }
Assert-True $threw 'unknown engine throws'

# Save / read engine choice
$tmp = Join-Path $env:TEMP ("autopro-engine-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $p = Save-EngineChoice -ScratchDir $tmp -Engine 'codex' -Model 'o3' -SessionId 'sess_test' -Display 'codex (test)'
  Assert-True (Test-Path -LiteralPath $p) 'save engine choice'
  $read = Read-EngineChoice -ScratchDir $tmp
  Assert-True ($read.engine -eq 'codex') 'read engine choice'
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# Risk labels
foreach ($e in $script:AutoproKnownEngines) {
  $lab = Get-EngineRiskLabel -Engine $e
  Assert-True ($lab -and $lab.Length -gt 2) "risk label $e"
}

Write-Output ''
if ($failed -eq 0) {
  Write-Output 'PASS test-worker-engines'
  exit 0
} else {
  Write-Output "FAIL count=$failed"
  exit 1
}
