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
