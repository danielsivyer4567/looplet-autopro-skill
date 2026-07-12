<#
  autopro-doctor.ps1 — prompt-and-play preflight for AutoPro / Show Time.

  Checks engines, ledger, independent gate, Show Time board, and risk readiness
  WITHOUT arming a runner. Safe to run anytime.

  Usage:
    pwsh -File autopro-doctor.ps1
    pwsh -File autopro-doctor.ps1 -RepoDir <repo>
    pwsh -File autopro-doctor.ps1 -RepoDir <repo> -Engine codex
#>
param(
  [string]$RepoDir = (Get-Location).Path,
  [string]$Root = '',
  [string]$Engine = 'auto',
  [switch]$AllowOllama,
  [switch]$Json
)

$ErrorActionPreference = 'Continue'
$SkillScripts = $PSScriptRoot
. (Join-Path $SkillScripts 'worker-engines.ps1')
. (Join-Path $SkillScripts 'showtime-final-check.ps1')

if (-not $Root) { $Root = $RepoDir }
$scratch = Join-Path $Root '.claude\scratch'
$ledger = Join-Path $RepoDir '.claude\scratch\ledger.md'
$report = [ordered]@{
  ok            = $true
  repoDir       = $RepoDir
  root          = $Root
  engines       = @()
  selectedEngine = $null
  ledger        = $null
  independentGate = $null
  showTime      = $null
  env           = @{}
  hints         = [System.Collections.Generic.List[string]]::new()
}

# --- Engines ---
$all = Get-AllEngineResolutions
$report.engines = @($all | ForEach-Object {
    $ver = Test-EngineVersion -Resolution $_
    [ordered]@{
      engine    = $_.Engine
      available = $_.Available
      agentic   = $_.Agentic
      display   = $_.Display
      hint      = $_.Hint
      versionOk = $ver.Ok
      version   = $ver.Version
    }
  })
if (-not $Json) {
  Write-Output '==== autopro doctor ===='
  Write-Output (Format-EnginePreflightReport -Resolutions $all)
  Write-Output 'ENGINE_VERSIONS'
  foreach ($e in $report.engines) {
    $flag = if ($e.versionOk) { 'OK ' } else { '—  ' }
    $v = if ($e.version) { $e.version } else { $e.hint }
    Write-Output ("  [{0}] {1,-7} {2}" -f $flag, $e.engine, $v)
  }
}

try {
  $sel = Resolve-AutoproEngine -Requested $Engine -AllowOllama:$AllowOllama -Quiet
  $report.selectedEngine = [ordered]@{
    requested = $Engine
    engine    = $sel.Engine
    display   = $sel.Display
    risk      = (Get-EngineRiskLabel -Engine $sel.Engine)
  }
  if (-not $Json) {
    Write-Output ("SELECTED engine={0}  risk={1}" -f $sel.Engine, (Get-EngineRiskLabel -Engine $sel.Engine))
    Write-Output ("  {0}" -f $sel.Display)
  }
} catch {
  $report.ok = $false
  $report.hints.Add([string]$_.Exception.Message) | Out-Null
  if (-not $Json) { Write-Output ("SELECTED FAIL: {0}" -f $_.Exception.Message) }
}

# --- Ledger ---
$ledgerOk = $false
$approved = $false
if (Test-Path -LiteralPath $ledger) {
  $raw = Get-Content -LiteralPath $ledger -Raw
  $approved = [bool]([regex]::IsMatch($raw, '(?im)^Approved:\s*yes'))
  $pending = ([regex]::Matches($raw, '(?m)^##\s+(?:SC-\d+|SD-[\w-]+|H\d+|P\d+[-\w]*)[^\n]*\[pending\]')).Count
  $done = ([regex]::Matches($raw, '(?m)^##\s+(?:SC-\d+|SD-[\w-]+|H\d+|P\d+[-\w]*)[^\n]*\[done\]')).Count
  $ledgerOk = $true
  $report.ledger = [ordered]@{ path = $ledger; exists = $true; approved = $approved; pending = $pending; done = $done }
  if (-not $approved) {
    $report.ok = $false
    $report.hints.Add('Ledger exists but Approved: yes is missing — approve before -autopro') | Out-Null
  }
  if (-not $Json) {
    Write-Output ("LEDGER path={0} approved={1} pending={2} done={3}" -f $ledger, $approved, $pending, $done)
  }
} else {
  $report.ok = $false
  $report.ledger = [ordered]@{ path = $ledger; exists = $false }
  $report.hints.Add("No ledger at $ledger — run ledger skill first") | Out-Null
  if (-not $Json) { Write-Output "LEDGER missing: $ledger" }
}

# --- Independent gate ---
$gate = Resolve-IndependentFinalGate -WorkDir $RepoDir
$report.independentGate = [ordered]@{ kind = $gate.Kind; display = $gate.Display }
if ($gate.Kind -eq 'none') {
  $report.hints.Add('No independent final gate (package.json scripts.gate / scripts/final-check.ps1 / AUTOPRO_FINAL_CHECK_CMD). Arm needs -AllowModelOnlyFinalCheck (risky) or configure a gate.') | Out-Null
}
if (-not $Json) {
  Write-Output ("GATE kind={0} display={1}" -f $gate.Kind, $gate.Display)
}

# --- Show Time ---
$portFile = Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater\server.port'
$tokenFile = Join-Path $env:USERPROFILE '.claude\scratch\autopro-theater\server.token'
$port = $null
if (Test-Path -LiteralPath $portFile) {
  $p = (Get-Content -LiteralPath $portFile -Raw).Trim()
  if ($p -match '^\d+$') { $port = [int]$p }
}
$boardUp = $false
if ($port) {
  try {
    $h = Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/health" -TimeoutSec 2
    $boardUp = $true
    $report.showTime = [ordered]@{ up = $true; port = $port; health = $h }
  } catch {
    $report.showTime = [ordered]@{ up = $false; port = $port; error = $_.Exception.Message }
  }
} else {
  $report.showTime = [ordered]@{ up = $false; port = $null; note = 'no server.port yet (ok — launch will start it)' }
}
if (-not $Json) {
  Write-Output ("SHOWTIME up={0} port={1}" -f $boardUp, $(if ($port) { $port } else { '—' }))
}

# --- Env hints ---
foreach ($k in @('AUTOPRO_ENGINE', 'AUTOPRO_MODEL', 'AUTOPRO_ENGINE_ORDER', 'AUTOPRO_VERIFIER_ENGINE', 'ANTHROPIC_MODEL', 'OPENAI_API_KEY', 'GOOGLE_API_KEY')) {
  $v = [Environment]::GetEnvironmentVariable($k)
  if ($v) { $report.env[$k] = if ($k -match 'KEY|TOKEN|SECRET') { '(set)' } else { $v } }
}
if (-not $Json -and $report.env.Count) {
  Write-Output 'ENV (relevant):'
  foreach ($k in $report.env.Keys) { Write-Output ("  {0}={1}" -f $k, $report.env[$k]) }
}

# --- Arm recipe ---
if (-not $Json) {
  Write-Output ''
  Write-Output '==== arm recipe (copy/paste when ready) ===='
  $engFlag = if ($Engine -and $Engine -ne 'auto') { " -Engine $Engine" } else { '' }
  Write-Output @"
pwsh -NoProfile -File `"$SkillScripts\launch-showtime.ps1`" ``
  -Root `"$Root`" -RepoDir `"$RepoDir`" ``
  -AllowDangerousSkipPermissions -IAcceptUnattendedRisk$engFlag
"@
  if ($report.hints.Count) {
    Write-Output ''
    Write-Output 'HINTS:'
    foreach ($h in $report.hints) { Write-Output ("  • {0}" -f $h) }
  }
  Write-Output ''
  Write-Output ("STATUS={0}" -f $(if ($report.ok -and $report.selectedEngine) { 'ready' } else { 'needs-attention' }))
}

if ($Json) {
  $report.ok = [bool]($report.ok -and $report.selectedEngine)
  $report | ConvertTo-Json -Depth 6
}

if ($report.ok -and $report.selectedEngine) { exit 0 } else { exit 1 }
