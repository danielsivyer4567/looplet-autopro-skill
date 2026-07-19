<#
  showtime-final-check.ps1 — decode `claude -p` stdout and decide the final-check verdict.

  Dot-sourced by autopro-runner.ps1 (the merge gate) and by test-showtime.ps1, so the
  predicate that decides whether an epic merges has exactly one implementation and one
  set of tests.

  `claude -p --output-format json` returns the assistant text inside a JSON string, so
  newlines arrive as the two characters \ and n. A regex anchored with ^ never sees a
  line start, and \b before a word preceded by "\n" sees "n" — a word character — and
  fails too. Decode before matching.
#>

function ConvertFrom-ClaudeOutput {
  param([string]$Raw)
  if (-not $Raw) { return '' }

  $texts = [System.Collections.Generic.List[string]]::new()
  $candidates = [System.Collections.Generic.List[string]]::new()

  $trimmed = $Raw.Trim()
  if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) { [void]$candidates.Add($trimmed) }
  # --verbose can interleave one JSON object per line
  foreach ($line in ($Raw -split "`r?`n")) {
    $l = $line.Trim()
    if ($l.Length -gt 1 -and $l.StartsWith('{') -and $l.EndsWith('}')) { [void]$candidates.Add($l) }
  }

  foreach ($c in $candidates) {
    $obj = $null
    try { $obj = $c | ConvertFrom-Json -ErrorAction Stop } catch { continue }
    foreach ($node in @($obj)) {
      if ($null -ne $node.result) { [void]$texts.Add([string]$node.result); continue }
      if ($node.message -and $node.message.content) {
        foreach ($blk in @($node.message.content)) {
          if ($blk.type -eq 'text' -and $blk.text) { [void]$texts.Add([string]$blk.text) }
        }
      }
    }
  }

  if ($texts.Count) { return ($texts -join "`n") }
  return $Raw
}

function Get-FinalCheckProbe {
  # Matching-only view. Collapsing literal \n escapes is safe here because the result is
  # never persisted — it exists solely so ^ and \b behave on un-decodable output.
  param([string]$Text)
  if (-not $Text) { return '' }
  return (($Text -replace '\\r\\n', "`n") -replace '\\n', "`n")
}

function Test-FinalCheckGreen {
  param([object]$Result)
  if ($null -eq $Result) { return $false }
  if ([int]$Result.ExitCode -ne 0) { return $false }

  $probe = Get-FinalCheckProbe (ConvertFrom-ClaudeOutput ([string]$Result.Text))
  if (-not $probe) { return $false }

  # Red is tested first and wins. A model that narrates "I print green, not red" must
  # never merge; refusing a green epic is recoverable, merging a red one is not.
  if ($probe -match '(?i)FINAL_CHECK_STATUS\s*=\s*red\b') { return $false }
  if ($probe -match '(?i)FINAL_CHECK_STATUS\s*=\s*green\b') { return $true }

  # Marker absent (older check skill, truncated output): fall back to prose, still
  # biased to blocking.
  if ($probe -match '(?i)\b(check\s+green|green\s+check|epic\s+complete)\b' -and
      $probe -notmatch '(?i)\b(red|fail(?:ed|ure)?|error|blocked)\b') {
    return $true
  }
  return $false
}

<#
  Resolve-IndependentFinalGate — what command proves the epic before merge.
  Priority: env AUTOPRO_FINAL_CHECK_CMD → scripts/final-check.ps1 → package.json scripts.gate.
  Returns: @{ Kind = 'env'|'script'|'npm-gate'|'none'; Display = string; Command = string; Args = string[] }
#>
function Resolve-IndependentFinalGate {
  param([Parameter(Mandatory = $true)][string]$WorkDir)

  $none = @{ Kind = 'none'; Display = 'none'; Command = ''; Args = @() }
  if (-not $WorkDir -or -not (Test-Path -LiteralPath $WorkDir)) { return $none }

  $envCmd = [string]$env:AUTOPRO_FINAL_CHECK_CMD
  if ($envCmd -and $envCmd.Trim()) {
    return @{
      Kind    = 'env'
      Display = "AUTOPRO_FINAL_CHECK_CMD=$($envCmd.Trim())"
      Command = $envCmd.Trim()
      Args    = @()
    }
  }

  $finalPs1 = Join-Path $WorkDir 'scripts\final-check.ps1'
  if (Test-Path -LiteralPath $finalPs1) {
    return @{
      Kind    = 'script'
      Display = 'scripts/final-check.ps1'
      Command = 'pwsh'
      Args    = @('-NoProfile', '-File', $finalPs1)
    }
  }

  $pkg = Join-Path $WorkDir 'package.json'
  if (Test-Path -LiteralPath $pkg) {
    try {
      $raw = Get-Content -LiteralPath $pkg -Raw -ErrorAction Stop
      if ($raw -match '"gate"\s*:\s*"') {
        return @{
          Kind    = 'npm-gate'
          Display = 'npm run gate'
          Command = 'npm'
          Args    = @('run', 'gate')
        }
      }
    } catch {}
  }

  return $none
}

<#
  Invoke-IndependentFinalGate — run the resolved gate and return a verdict object.
  Called by autopro-runner after the model FINAL_CHECK_STATUS=green marker.

  Returns:
    @{
      Ok, ExitCode, Text, Kind, Display
    }
#>
function Invoke-IndependentFinalGate {
  param(
    [Parameter(Mandatory = $true)][string]$WorkDir,
    [switch]$AllowModelOnly
  )

  $spec = Resolve-IndependentFinalGate -WorkDir $WorkDir
  if ($spec.Kind -eq 'none') {
    if ($AllowModelOnly) {
      return [pscustomobject]@{
        Ok       = $true
        ExitCode = 0
        Text     = 'INDEPENDENT_GATE=skipped (AllowModelOnlyFinalCheck)'
        Kind     = 'none'
        Display  = 'model-only'
      }
    }
    return [pscustomobject]@{
      Ok       = $false
      ExitCode = 78
      Text     = 'INDEPENDENT_GATE=none — configure scripts/final-check.ps1, package.json scripts.gate, or AUTOPRO_FINAL_CHECK_CMD'
      Kind     = 'none'
      Display  = 'none'
    }
  }

  $exe = [string]$spec.Command
  $args = @($spec.Args)
  $text = ''
  $code = -1

  try {
    # env kind may be a full shell line (e.g. "pwsh -File x.ps1" or "npm test")
    if ($spec.Kind -eq 'env') {
      $psi = [System.Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = if ($IsWindows -or $null -eq $IsWindows) { 'cmd.exe' } else { '/bin/sh' }
      $psi.Arguments = if ($IsWindows -or $null -eq $IsWindows) { "/c $($spec.Command)" } else { "-c `"$($spec.Command)`"" }
      $psi.WorkingDirectory = $WorkDir
      $psi.UseShellExecute = $false
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $psi.CreateNoWindow = $true
      $proc = [System.Diagnostics.Process]::Start($psi)
      $stdout = $proc.StandardOutput.ReadToEnd()
      $stderr = $proc.StandardError.ReadToEnd()
      if (-not $proc.WaitForExit(600000)) {
        try { $proc.Kill($true) } catch { try { $proc.Kill() } catch {} }
        $code = 124
        $text = "INDEPENDENT_GATE_TIMEOUT after 600s`n$stdout`n$stderr"
      } else {
        $code = $proc.ExitCode
        $text = (@($stdout, $stderr) | Where-Object { $_ }) -join "`n"
      }
      try { $proc.Dispose() } catch {}
    } else {
      # script / npm-gate: FileName + Args
      $psi = [System.Diagnostics.ProcessStartInfo]::new()
      # Resolve pwsh/npm on PATH
      $cmdInfo = Get-Command $exe -ErrorAction SilentlyContinue
      $psi.FileName = if ($cmdInfo -and $cmdInfo.Source) { $cmdInfo.Source } else { $exe }
      $psi.WorkingDirectory = $WorkDir
      $psi.UseShellExecute = $false
      $psi.RedirectStandardOutput = $true
      $psi.RedirectStandardError = $true
      $psi.CreateNoWindow = $true
      foreach ($a in $args) {
        if ($null -ne $a -and [string]$a -ne '') { [void]$psi.ArgumentList.Add([string]$a) }
      }
      $proc = [System.Diagnostics.Process]::Start($psi)
      $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
      $stderrTask = $proc.StandardError.ReadToEndAsync()
      if (-not $proc.WaitForExit(600000)) {
        try { $proc.Kill($true) } catch { try { $proc.Kill() } catch {} }
        $code = 124
        $text = 'INDEPENDENT_GATE_TIMEOUT after 600s'
      } else {
        $code = $proc.ExitCode
        $stdout = ''; $stderr = ''
        try { $stdout = $stdoutTask.GetAwaiter().GetResult() } catch {}
        try { $stderr = $stderrTask.GetAwaiter().GetResult() } catch {}
        $text = (@($stdout, $stderr) | Where-Object { $_ }) -join "`n"
      }
      try { $proc.Dispose() } catch {}
    }
  } catch {
    return [pscustomobject]@{
      Ok       = $false
      ExitCode = 1
      Text     = ("INDEPENDENT_GATE_THROW: {0}" -f $_.Exception.Message)
      Kind     = $spec.Kind
      Display  = $spec.Display
    }
  }

  $ok = ($code -eq 0)
  # Optional: if gate prints FINAL_CHECK_STATUS=red, fail even on exit 0
  if ($ok -and $text -match '(?i)FINAL_CHECK_STATUS\s*=\s*red\b') { $ok = $false }
  return [pscustomobject]@{
    Ok       = [bool]$ok
    ExitCode = [int]$code
    Text     = [string]$text
    Kind     = $spec.Kind
    Display  = $spec.Display
  }
}
