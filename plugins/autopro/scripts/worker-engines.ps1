<#
  worker-engines.ps1 — multi-engine worker adapters for AutoPro / Show Time.

  Supported engines (slice executors):
    claude | codex | gemini | grok | ollama

  Auto order (default -Engine auto):
    claude → codex → gemini → grok
    (ollama is NEVER auto-selected — no agent tool loop by default)

  Design rules:
    - Never launch npm *.ps1 / *.cmd shims via ProcessStartInfo (argv collapse).
    - Prefer real .exe or `node path/to/cli.js …`.
    - Unattended requires engine-specific skip-permissions / yolo / always-approve.
    - Dot-source from launch-showtime.ps1, autopro-runner.ps1, autopro-doctor.ps1.

  Env overrides:
    AUTOPRO_ENGINE          preferred engine id (or "auto")
    AUTOPRO_MODEL           default model pin
    AUTOPRO_VERIFIER_ENGINE optional separate verifier engine
    AUTOPRO_ENGINE_ORDER    comma list override for auto (e.g. "codex,claude,gemini")
#>

#Requires -Version 7.0

# `stub` is soak/offline only — NEVER in auto order (no real coding).
$script:AutoproKnownEngines = @('claude', 'codex', 'gemini', 'grok', 'ollama', 'stub')
$script:AutoproAutoOrderDefault = @('claude', 'codex', 'gemini', 'grok')

function Get-AutoproAutoOrder {
  $raw = [string]$env:AUTOPRO_ENGINE_ORDER
  if ($raw -and $raw.Trim()) {
    $parts = @($raw.Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ -in $script:AutoproKnownEngines -and $_ -ne 'ollama' })
    if ($parts.Count) { return $parts }
  }
  return @($script:AutoproAutoOrderDefault)
}

# pwsh 7 automatic; on Windows PowerShell 5.1 it's undefined → treat as Windows.
$script:AutoproEnginesOnWindows = ($null -eq $IsWindows) -or $IsWindows

# Null-safe Join-Path: the Windows exe-search roots ($env:ProgramFiles, $env:APPDATA, …) are $null on
# Unix, and Join-Path throws on a null root. Returns $null so the caller's `if ($cand -and …)` skips it.
function Join-WinRoot([string]$Root, [string]$Child) {
  if ([string]::IsNullOrEmpty($Root)) { return $null }
  return (Join-Path $Root $Child)
}

# Cross-OS PATH lookup for the Unix branches: return the first name that resolves to a real file.
function Resolve-CliByName([string[]]$Names) {
  foreach ($n in $Names) {
    $c = Get-Command $n -ErrorAction SilentlyContinue
    if ($c -and $c.Source -and (Test-Path -LiteralPath $c.Source)) { return $c.Source }
  }
  return $null
}

function Get-NodeExe {
  # Unix: PATH node (extensionless); the .exe-only checks below are a Windows shim-avoidance concern.
  if (-not $script:AutoproEnginesOnWindows) { return (Resolve-CliByName -Names @('node')) }
  $c = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($c -and $c.Source -and (Test-Path -LiteralPath $c.Source)) { return $c.Source }
  $c2 = Get-Command node -ErrorAction SilentlyContinue
  if ($c2 -and $c2.Source -and ($c2.Source -match '\.exe$') -and (Test-Path -LiteralPath $c2.Source)) { return $c2.Source }
  foreach ($cand in @(
      (Join-WinRoot $env:ProgramFiles 'nodejs\node.exe'),
      (Join-WinRoot ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
      (Join-WinRoot $env:LOCALAPPDATA 'Programs\node\node.exe')
    )) {
    if ($cand -and (Test-Path -LiteralPath $cand)) { return $cand }
  }
  return $null
}

function Resolve-NpmPackageJs {
  param(
    [Parameter(Mandatory = $true)][string]$Package,
    [Parameter(Mandatory = $true)][string]$RelativeBin
  )
  # Unix: locate the global node_modules via `npm root -g` (portable across distros/managers).
  if (-not $script:AutoproEnginesOnWindows) {
    $gRoot = ''
    try { $gRoot = ([string](& npm root -g 2>$null | Select-Object -First 1)).Trim() } catch {}
    # Only join a value that is actually a directory — a broken/aliased npm can echo a non-path
    # string, and Join-Path would treat a "word:" prefix as a drive and throw.
    if ($gRoot -and (Test-Path -LiteralPath $gRoot -PathType Container)) {
      $full = Join-Path $gRoot (Join-Path $Package $RelativeBin)
      if (Test-Path -LiteralPath $full) { return $full }
    }
    return $null
  }
  $roots = @(
    (Join-WinRoot $env:APPDATA 'npm\node_modules'),
    (Join-WinRoot $env:LOCALAPPDATA 'npm\node_modules'),
    (Join-WinRoot $env:ProgramFiles 'nodejs\node_modules')
  )
  foreach ($root in $roots) {
    if (-not $root) { continue }
    $full = Join-Path $root (Join-Path $Package $RelativeBin)
    if (Test-Path -LiteralPath $full) { return $full }
  }
  return $null
}

function Resolve-ClaudeExe {
  <# Prefer real claude.exe — never npm's claude.ps1 / claude.cmd shims. #>
  # Unix: the shim problem is Windows-only; take PATH `claude` (a real binary there).
  if (-not $script:AutoproEnginesOnWindows) { return (Resolve-CliByName -Names @('claude')) }
  $candidates = @(
    (Join-WinRoot $env:USERPROFILE '.local\bin\claude.exe'),
    (Join-WinRoot $env:APPDATA 'npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe'),
    (Join-WinRoot $env:LOCALAPPDATA 'npm\claude.exe')
  )
  foreach ($cand in $candidates) {
    if ($cand -and (Test-Path -LiteralPath $cand) -and ($cand -match '\.exe$')) { return $cand }
  }
  $cmd = Get-Command claude.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source -and ($cmd.Source -match '\.exe$') -and (Test-Path -LiteralPath $cmd.Source)) {
    return $cmd.Source
  }
  return $null
}

function Resolve-GrokExe {
  # Unix: PATH `grok` (extensionless).
  if (-not $script:AutoproEnginesOnWindows) { return (Resolve-CliByName -Names @('grok')) }
  $candidates = @(
    (Join-WinRoot $env:USERPROFILE '.grok\bin\grok.exe'),
    (Join-WinRoot $env:LOCALAPPDATA 'Programs\grok\grok.exe')
  )
  foreach ($cand in $candidates) {
    if ($cand -and (Test-Path -LiteralPath $cand)) { return $cand }
  }
  $cmd = Get-Command grok.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) { return $cmd.Source }
  $cmd2 = Get-Command grok -ErrorAction SilentlyContinue
  if ($cmd2 -and $cmd2.Source -and ($cmd2.Source -match '\.exe$') -and (Test-Path -LiteralPath $cmd2.Source)) {
    return $cmd2.Source
  }
  return $null
}

function Resolve-OllamaExe {
  # Unix: PATH `ollama` (extensionless).
  if (-not $script:AutoproEnginesOnWindows) { return (Resolve-CliByName -Names @('ollama')) }
  $candidates = @(
    (Join-WinRoot $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
    (Join-WinRoot $env:ProgramFiles 'Ollama\ollama.exe')
  )
  foreach ($cand in $candidates) {
    if ($cand -and (Test-Path -LiteralPath $cand)) { return $cand }
  }
  $cmd = Get-Command ollama.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) { return $cmd.Source }
  return $null
}

function New-EngineResolution {
  param(
    [string]$Engine,
    [bool]$Available,
    [string]$Kind = '',          # exe | node-js | none
    [string]$FileName = '',
    [string[]]$PrefixArgs = @(),
    [string]$Display = '',
    [string]$Hint = '',
    [bool]$Agentic = $true,
    [string]$DefaultModel = ''
  )
  [pscustomobject]@{
    Engine       = $Engine
    Available    = [bool]$Available
    Kind         = $Kind
    FileName     = $FileName
    PrefixArgs   = @($PrefixArgs)
    Display      = $(if ($Display) { $Display } else { $Engine })
    Hint         = $Hint
    Agentic      = [bool]$Agentic
    DefaultModel = $DefaultModel
  }
}

function Resolve-EngineBinary {
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('claude', 'codex', 'gemini', 'grok', 'ollama', 'stub')]
    [string]$Engine
  )

  switch ($Engine) {
    'claude' {
      $exe = Resolve-ClaudeExe
      if ($exe) {
        return (New-EngineResolution -Engine claude -Available $true -Kind exe -FileName $exe `
            -Display "claude ($exe)" -DefaultModel '' -Hint 'Claude Code CLI')
      }
      return (New-EngineResolution -Engine claude -Available $false -Kind none `
          -Hint 'Install Claude Code CLI (claude.exe). npm claude.ps1 alone is not enough.')
    }
    'codex' {
      $js = Resolve-NpmPackageJs -Package '@openai/codex' -RelativeBin 'bin/codex.js'
      $node = Get-NodeExe
      if ($js -and $node) {
        return (New-EngineResolution -Engine codex -Available $true -Kind node-js -FileName $node `
            -PrefixArgs @($js) -Display "codex (node $js)" -DefaultModel '' `
            -Hint 'OpenAI Codex CLI via node')
      }
      return (New-EngineResolution -Engine codex -Available $false -Kind none `
          -Hint 'Install: npm i -g @openai/codex  (and Node.js)')
    }
    'gemini' {
      $js = Resolve-NpmPackageJs -Package '@google/gemini-cli' -RelativeBin 'bundle/gemini.js'
      $node = Get-NodeExe
      if ($js -and $node) {
        return (New-EngineResolution -Engine gemini -Available $true -Kind node-js -FileName $node `
            -PrefixArgs @($js) -Display "gemini (node $js)" -DefaultModel '' `
            -Hint 'Google Gemini CLI via node')
      }
      return (New-EngineResolution -Engine gemini -Available $false -Kind none `
          -Hint 'Install: npm i -g @google/gemini-cli  (and Node.js)')
    }
    'grok' {
      $exe = Resolve-GrokExe
      if ($exe) {
        return (New-EngineResolution -Engine grok -Available $true -Kind exe -FileName $exe `
            -Display "grok ($exe)" -DefaultModel '' -Hint 'Grok Build / Grok CLI')
      }
      return (New-EngineResolution -Engine grok -Available $false -Kind none `
          -Hint 'Install Grok CLI (grok.exe under ~/.grok/bin)')
    }
    'ollama' {
      $exe = Resolve-OllamaExe
      if ($exe) {
        return (New-EngineResolution -Engine ollama -Available $true -Kind exe -FileName $exe `
            -Display "ollama ($exe)" -DefaultModel 'llama3.2' -Agentic $false `
            -Hint 'Local Ollama — text only by default (no agent tools). Explicit -Engine ollama required.')
      }
      return (New-EngineResolution -Engine ollama -Available $false -Kind none -Agentic $false `
          -Hint 'Install Ollama from https://ollama.com')
    }
    'stub' {
      # Offline soak worker: marks one ledger slice [done] + commits soak-out/<id>.txt
      $node = Get-NodeExe
      $stubJs = Join-Path $PSScriptRoot 'stub-worker.mjs'
      if ($node -and (Test-Path -LiteralPath $stubJs)) {
        return (New-EngineResolution -Engine stub -Available $true -Kind node-js -FileName $node `
            -PrefixArgs @($stubJs) -Display "stub (soak · $stubJs)" -DefaultModel 'stub-soak' `
            -Hint 'Offline soak worker — pin with -Engine stub (never auto)')
      }
      return (New-EngineResolution -Engine stub -Available $false -Kind none `
          -Hint 'Need node + scripts/stub-worker.mjs for -Engine stub')
    }
  }
}

function Get-AllEngineResolutions {
  $list = [System.Collections.Generic.List[object]]::new()
  foreach ($e in $script:AutoproKnownEngines) {
    $list.Add((Resolve-EngineBinary -Engine $e)) | Out-Null
  }
  return @($list)
}

function Resolve-AutoproEngine {
  <#
    Resolve requested engine id ("auto" or explicit).
    Returns resolution object with .Engine filled; throws if none available.
  #>
  param(
    [string]$Requested = 'auto',
    [switch]$AllowOllama,
    [switch]$Quiet
  )

  $req = if ($Requested -and $Requested.Trim()) { $Requested.Trim().ToLowerInvariant() } else { 'auto' }
  if ($env:AUTOPRO_ENGINE -and $req -eq 'auto') {
    # Only honor env when caller left default auto
    $envEng = $env:AUTOPRO_ENGINE.Trim().ToLowerInvariant()
    if ($envEng) { $req = $envEng }
  }

  if ($req -ne 'auto') {
    if ($req -notin $script:AutoproKnownEngines) {
      throw "Unknown engine '$req'. Known: $($script:AutoproKnownEngines -join ', '), or auto."
    }
    if ($req -eq 'ollama' -and -not $AllowOllama) {
      throw @"
Engine 'ollama' is local text-only by default (no repo tool loop).
Pass -AllowOllama if you really want it for experiments, or pick claude/codex/gemini/grok.
"@
    }
    $res = Resolve-EngineBinary -Engine $req
    if (-not $res.Available) {
      throw "Engine '$req' not available. $($res.Hint)"
    }
    return $res
  }

  # auto
  $order = Get-AutoproAutoOrder
  $tried = [System.Collections.Generic.List[string]]::new()
  foreach ($e in $order) {
    $res = Resolve-EngineBinary -Engine $e
    $tried.Add(("{0}={1}" -f $e, $(if ($res.Available) { 'yes' } else { 'no' }))) | Out-Null
    if ($res.Available) {
      if (-not $Quiet) {
        Write-Verbose ("autopro engine auto → {0} ({1})" -f $res.Engine, $res.Display)
      }
      return $res
    }
  }

  $all = Get-AllEngineResolutions
  $hints = ($all | ForEach-Object { "  - $($_.Engine): $($_.Hint)" }) -join "`n"
  throw @"
No agentic worker engine found on this machine (auto order: $($order -join ' → ')).
Probed: $($tried -join ', ')

Install at least one of Claude Code, Codex, Gemini CLI, or Grok CLI:
$hints

Then re-run, or pin: -Engine claude|codex|gemini|grok
"@
}

function Build-WorkerArgumentList {
  <#
    Build argv AFTER FileName (+ PrefixArgs for node-js).
    Returns string[] of args to append.
  #>
  param(
    [Parameter(Mandatory = $true)]$Resolution,
    [Parameter(Mandatory = $true)][string]$Prompt,
    [string]$ModelName = '',
    [string]$WorkDir = '',
    [switch]$SkipPermissions
  )

  $engine = [string]$Resolution.Engine
  $model = if ($ModelName -and $ModelName.Trim()) { $ModelName.Trim() } else { '' }
  if (-not $model -and $Resolution.DefaultModel) { $model = [string]$Resolution.DefaultModel }

  switch ($engine) {
    'claude' {
      $args = [System.Collections.Generic.List[string]]::new()
      if ($model) { [void]$args.Add('--model'); [void]$args.Add($model) }
      [void]$args.Add('--verbose')
      if ($SkipPermissions) { [void]$args.Add('--dangerously-skip-permissions') }
      [void]$args.Add('--output-format'); [void]$args.Add('json')
      [void]$args.Add('-p'); [void]$args.Add($Prompt)
      return @($args)
    }
    'codex' {
      # codex exec — non-interactive agent.
      # Prompt on argv. Stdin is redirected+closed by the runner (empty EOF) so
      # codex does not block on "Reading additional input from stdin…".
      # Do NOT use `-` (stdin prompt): that path hung in smoke tests on Windows.
      $args = [System.Collections.Generic.List[string]]::new()
      [void]$args.Add('exec')
      [void]$args.Add('--json')
      [void]$args.Add('--color'); [void]$args.Add('never')
      if ($WorkDir) { [void]$args.Add('-C'); [void]$args.Add($WorkDir) }
      if ($model) { [void]$args.Add('-m'); [void]$args.Add($model) }
      if ($SkipPermissions) {
        [void]$args.Add('--dangerously-bypass-approvals-and-sandbox')
      } else {
        [void]$args.Add('-s'); [void]$args.Add('workspace-write')
      }
      [void]$args.Add($Prompt)
      return @($args)
    }
    'gemini' {
      # Headless: -p prompt. Prefer auto_edit over -y — many installs disable YOLO
      # via admin policy ("disableYolo") and -y fails immediately.
      $args = [System.Collections.Generic.List[string]]::new()
      if ($model) { [void]$args.Add('-m'); [void]$args.Add($model) }
      if ($SkipPermissions) {
        [void]$args.Add('--approval-mode'); [void]$args.Add('auto_edit')
      } else {
        [void]$args.Add('--approval-mode'); [void]$args.Add('default')
      }
      [void]$args.Add('--skip-trust')
      [void]$args.Add('-p'); [void]$args.Add($Prompt)
      return @($args)
    }
    'grok' {
      # Headless agentic: -p/--single with always-approve + bypassPermissions.
      # Positional prompt without -p opens the TUI and hangs under CreateNoWindow
      # (smoke: GROK1 TIMEOUT). -p still runs tools (smoke: read a.txt → "hello").
      # --max-turns keeps multi-step ledger work inside one process.
      $args = [System.Collections.Generic.List[string]]::new()
      if ($WorkDir) { [void]$args.Add('--cwd'); [void]$args.Add($WorkDir) }
      if ($model) { [void]$args.Add('-m'); [void]$args.Add($model) }
      if ($SkipPermissions) {
        [void]$args.Add('--always-approve')
        [void]$args.Add('--permission-mode'); [void]$args.Add('bypassPermissions')
      }
      [void]$args.Add('--output-format'); [void]$args.Add('json')
      [void]$args.Add('--max-turns'); [void]$args.Add('80')
      [void]$args.Add('-p'); [void]$args.Add($Prompt)
      return @($args)
    }
    'ollama' {
      $args = [System.Collections.Generic.List[string]]::new()
      [void]$args.Add('run')
      $m = if ($model) { $model } else { 'llama3.2' }
      [void]$args.Add($m)
      [void]$args.Add($Prompt)
      return @($args)
    }
    'stub' {
      $args = [System.Collections.Generic.List[string]]::new()
      if ($WorkDir) { [void]$args.Add('--cwd'); [void]$args.Add($WorkDir) }
      [void]$args.Add('-p'); [void]$args.Add($Prompt)
      return @($args)
    }
    default { throw "Build-WorkerArgumentList: unknown engine $engine" }
  }
}

function Get-WorkerProcessMatchers {
  <# Patterns used by stop-autopro to find orphan workers. #>
  return @(
    @{ Name = 'claude'; Pattern = 'claude(\.exe)?|@anthropic-ai\\claude-code' }
    @{ Name = 'codex'; Pattern = 'codex(\.exe)?|@openai\\codex|bin\\codex\.js' }
    @{ Name = 'gemini'; Pattern = 'gemini(\.exe)?|@google\\gemini-cli|bundle\\gemini\.js' }
    @{ Name = 'grok'; Pattern = 'grok(\.exe)?|\\.grok\\bin\\grok' }
    @{ Name = 'ollama'; Pattern = 'ollama(\.exe)?' }
    @{ Name = 'stub'; Pattern = 'stub-worker\.mjs' }
    @{ Name = 'node-worker'; Pattern = 'node(\.exe)?.+(codex\.js|gemini\.js|stub-worker\.mjs)' }
  )
}

function Test-WorkerCommandLine {
  param([string]$CommandLine)
  if (-not $CommandLine) { return $false }
  foreach ($m in (Get-WorkerProcessMatchers)) {
    if ($CommandLine -match $m.Pattern) { return $true }
  }
  return $false
}

function Parse-WorkerUsageFromText {
  <# Best-effort token/cost/model extraction across engines. #>
  param([string]$Text, [string]$Engine = '')

  $result = [pscustomobject]@{
    model        = ''
    input        = 0
    output       = 0
    cacheCreate  = 0
    cacheRead    = 0
    costUsd      = 0.0
    measured     = $false
  }
  if (-not $Text) { return $result }

  # Strip runner log prefixes if present
  $clean = ($Text -split "`r?`n" | ForEach-Object {
      if ($_ -match '^\s+\|\s') { $_.Substring($Matches[0].Length) } else { $_ }
    }) -join "`n"

  # Claude-style result JSON (often last JSON object)
  $modelId = ''
  $nodes = [System.Collections.Generic.List[object]]::new()

  # Try whole-text JSON first
  try {
    $j = $clean | ConvertFrom-Json -ErrorAction Stop
    if ($j) {
      # ConvertFrom-Json returns Object[] for a top-level JSON array. Adding the
      # array as one node makes fields such as total_cost_usd become Object[],
      # which later cannot be converted to a scalar Double. Flatten only the
      # top-level result; individual event objects remain intact.
      foreach ($item in @($j)) { if ($item) { [void]$nodes.Add($item) } }
    }
  } catch {}

  # JSONL / multi-object: scan lines
  foreach ($line in ($clean -split "`r?`n")) {
    $t = $line.Trim()
    if (-not $t) { continue }
    if ($t[0] -ne '{' -and $t[0] -ne '[') { continue }
    try {
      $node = $t | ConvertFrom-Json -ErrorAction Stop
      foreach ($item in @($node)) { if ($item) { [void]$nodes.Add($item) } }
    } catch {}
  }

  foreach ($node in $nodes) {
    if (-not $modelId) {
      if ($node.model) { $modelId = [string]$node.model }
      elseif ($node.message -and $node.message.model) { $modelId = [string]$node.message.model }
      elseif ($node.result -and $node.result.model) { $modelId = [string]$node.result.model }
    }
    $usage = $null
    if ($null -ne $node.usage) { $usage = $node.usage }
    elseif ($node.result -and $null -ne $node.result.usage) { $usage = $node.result.usage }
    elseif ($node.message -and $null -ne $node.message.usage) { $usage = $node.message.usage }
    if ($null -ne $usage) {
      $result.measured = $true
      # Prefer absolute assignment over += so multi-match JSONL doesn't double-count.
      $inVal = $null
      foreach ($k in @('input_tokens', 'inputTokens', 'prompt_tokens', 'input')) {
        if ($null -ne $usage.$k) { $inVal = [int]$usage.$k; break }
      }
      $outVal = $null
      foreach ($k in @('output_tokens', 'outputTokens', 'completion_tokens', 'output')) {
        if ($null -ne $usage.$k) { $outVal = [int]$usage.$k; break }
      }
      if ($null -ne $inVal) { $result.input = $inVal }
      if ($null -ne $outVal) { $result.output = $outVal }
      foreach ($k in @('cache_creation_input_tokens', 'cacheCreationInputTokens')) {
        if ($null -ne $usage.$k) { $result.cacheCreate = [int]$usage.$k; break }
      }
      foreach ($k in @('cache_read_input_tokens', 'cacheReadInputTokens')) {
        if ($null -ne $usage.$k) { $result.cacheRead = [int]$usage.$k; break }
      }
    }
    if ($null -ne $node.total_cost_usd) { $result.costUsd = [double]$node.total_cost_usd; $result.measured = $true }
    elseif ($node.result -and $null -ne $node.result.total_cost_usd) {
      $result.costUsd = [double]$node.result.total_cost_usd; $result.measured = $true
    }
  }

  if (-not $modelId -and $clean -match '"model"\s*:\s*"([^"]+)"') { $modelId = $Matches[1] }
  $result.model = $modelId
  return $result
}

function Format-EnginePreflightReport {
  param([object[]]$Resolutions)
  $lines = [System.Collections.Generic.List[string]]::new()
  [void]$lines.Add('ENGINE_PREFLIGHT')
  foreach ($r in $Resolutions) {
    $flag = if ($r.Available) { 'OK ' } else { 'NO ' }
    $agent = if ($r.Agentic) { 'agent' } else { 'text ' }
    [void]$lines.Add(("  [{0}] {1,-7} {2}  {3}" -f $flag, $r.Engine, $agent, $(if ($r.Available) { $r.Display } else { $r.Hint })))
  }
  return ($lines -join "`n")
}

function Save-EngineChoice {
  param(
    [Parameter(Mandatory = $true)][string]$ScratchDir,
    [Parameter(Mandatory = $true)][string]$Engine,
    [string]$Model = '',
    [string]$SessionId = '',
    [string]$Display = ''
  )
  if (-not (Test-Path -LiteralPath $ScratchDir)) {
    New-Item -ItemType Directory -Force -Path $ScratchDir | Out-Null
  }
  $path = Join-Path $ScratchDir 'autopro-engine.json'
  $obj = [ordered]@{
    engine    = $Engine
    model     = $Model
    sessionId = $SessionId
    display   = $Display
    savedAt   = (Get-Date).ToString('o')
  }
  ($obj | ConvertTo-Json -Compress) | Set-Content -LiteralPath $path -Encoding utf8
  return $path
}

function Read-EngineChoice {
  param([string]$ScratchDir)
  $path = Join-Path $ScratchDir 'autopro-engine.json'
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try {
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
  } catch { return $null }
}

function Get-EngineRiskLabel {
  param([string]$Engine)
  switch ($Engine) {
    'claude' { return '--dangerously-skip-permissions' }
    'codex'  { return '--dangerously-bypass-approvals-and-sandbox' }
    'gemini' { return '--approval-mode auto_edit (yolo often admin-disabled)' }
    'grok'   { return '--always-approve + bypassPermissions + -p' }
    'ollama' { return 'local (no remote approvals)' }
    'stub'   { return 'offline soak (no LLM; one slice per spawn)' }
    default  { return 'engine-specific unattended flags' }
  }
}

function Test-EngineVersion {
  <#
    Cheap smoke: spawn --version (no LLM). Returns pscustomobject.
  #>
  param(
    [Parameter(Mandatory = $true)]$Resolution,
    [int]$TimeoutMs = 8000
  )
  $out = [pscustomobject]@{
    Engine    = $Resolution.Engine
    Available = [bool]$Resolution.Available
    Ok        = $false
    ExitCode  = -1
    Version   = ''
    Error     = ''
    Ms        = 0
  }
  if (-not $Resolution.Available) {
    $out.Error = $Resolution.Hint
    return $out
  }
  try {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Resolution.FileName
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($a in @($Resolution.PrefixArgs)) {
      if ($null -ne $a -and [string]$a -ne '') { [void]$psi.ArgumentList.Add([string]$a) }
    }
    [void]$psi.ArgumentList.Add('--version')
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not $proc.Start()) { throw 'start failed' }
    if (-not $proc.WaitForExit($TimeoutMs)) {
      try { $proc.Kill($true) } catch {}
      $out.Error = 'timeout'
      $out.Ms = $sw.ElapsedMilliseconds
      return $out
    }
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $text = (($stdout + ' ' + $stderr) -replace '\s+', ' ').Trim()
    if ($text.Length -gt 160) { $text = $text.Substring(0, 160) + '…' }
    $out.ExitCode = $proc.ExitCode
    $out.Version = $text
    $out.Ok = ($proc.ExitCode -eq 0 -or $text.Length -gt 0)
    $out.Ms = $sw.ElapsedMilliseconds
    $proc.Dispose()
  } catch {
    $out.Error = $_.Exception.Message
  }
  return $out
}
