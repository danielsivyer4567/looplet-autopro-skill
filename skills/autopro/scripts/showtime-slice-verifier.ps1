<#
  showtime-slice-verifier.ps1 — post-slice verification policy (fail-closed).

  Dot-sourced by autopro-runner.ps1 after showtime-final-check.ps1.
  Owns the pure predicates only — the runner owns spawning the fresh
  `claude -p` verifier session and Playwright evidence path.

  Required surface (runner fails closed if any are missing):
    Test-AutoproUiChange
    Test-SliceVerificationGreen
    Get-SliceVerifierDecodedText
#>

function Test-AutoproUiChange {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object]$ChangedFiles
  )

  $files = @()
  if ($null -eq $ChangedFiles) { return $false }
  if ($ChangedFiles -is [string]) {
    $files = @($ChangedFiles)
  } else {
    $files = @($ChangedFiles | ForEach-Object { [string]$_ })
  }

  foreach ($raw in $files) {
    $f = [string]$raw
    if (-not $f) { continue }
    $n = $f -replace '\\', '/'
    # UI / front-end surfaces that need a real browser check when touched.
    if ($n -match '(?i)\.(css|scss|sass|less|html?|vue|svelte|jsx|tsx)$') { return $true }
    if ($n -match '(?i)/(components?|pages?|views?|layouts?|screens?|ui|styles?|public|static|assets)/') { return $true }
    if ($n -match '(?i)/(app|src)/(.*\.(jsx|tsx|vue|svelte|css|scss))$') { return $true }
    if ($n -match '(?i)(tailwind|postcss)\.config\.') { return $true }
    if ($n -match '(?i)\.(stories|story)\.(jsx?|tsx?)$') { return $true }
  }
  return $false
}

function Get-SliceVerifierDecodedText {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object]$Result
  )

  if ($null -eq $Result) { return '' }
  $raw = ''
  if ($Result -is [string]) {
    $raw = [string]$Result
  } elseif ($Result.PSObject -and ($Result.PSObject.Properties.Name -contains 'Text')) {
    $raw = [string]$Result.Text
  } else {
    $raw = [string]$Result
  }
  if (-not $raw) { return '' }

  # Prefer the shared Claude JSON decoder when final-check is already loaded.
  if (Get-Command ConvertFrom-ClaudeOutput -ErrorAction SilentlyContinue) {
    return (ConvertFrom-ClaudeOutput $raw)
  }

  # Minimal fallback: extract .result from JSON blobs, else raw.
  $trimmed = $raw.Trim()
  if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
    try {
      $obj = $trimmed | ConvertFrom-Json -ErrorAction Stop
      if ($null -ne $obj.result) { return [string]$obj.result }
    } catch {}
  }
  return $raw
}

function Get-SliceVerifyProbe {
  param([string]$Text)
  if (-not $Text) { return '' }
  # Matching-only: collapse literal \n so ^ / line anchors work on JSON-escaped text.
  return (($Text -replace '\\r\\n', "`n") -replace '\\n', "`n")
}

function Get-SliceVerifyMarker {
  param(
    [string]$Probe,
    [string]$Name
  )
  if (-not $Probe -or -not $Name) { return $null }
  $m = [regex]::Match($Probe, ("(?im)^\s*{0}\s*=\s*(\S+)\s*$" -f [regex]::Escape($Name)))
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  # Also tolerate inline (JSON-escaped single line) without line anchors.
  $m2 = [regex]::Match($Probe, ("(?i)\b{0}\s*=\s*(\S+)" -f [regex]::Escape($Name)))
  if ($m2.Success) { return $m2.Groups[1].Value.Trim() }
  return $null
}

function Test-SliceVerificationGreen {
  param(
    [Parameter(Mandatory = $true)]
    [AllowNull()]
    [object]$Result,

    [switch]$UiChanged,

    [string]$EvidencePath = ''
  )

  if ($null -eq $Result) { return $false }

  # Process must exit cleanly.
  if ($Result.PSObject.Properties.Name -contains 'ExitCode') {
    if ([int]$Result.ExitCode -ne 0) { return $false }
  }

  # Verifier is read-only — any tracked edit during verify is RED.
  if ($Result.PSObject.Properties.Name -contains 'WorktreeChanged') {
    if ([bool]$Result.WorktreeChanged) { return $false }
  }

  $decoded = Get-SliceVerifierDecodedText $Result
  $probe = Get-SliceVerifyProbe $decoded
  if (-not $probe) { return $false }

  $status = Get-SliceVerifyMarker -Probe $probe -Name 'SLICE_VERIFY_STATUS'
  if (-not $status) { return $false }
  if ($status -match '^(?i)red$') { return $false }
  if ($status -notmatch '^(?i)green$') { return $false }

  $pw = Get-SliceVerifyMarker -Probe $probe -Name 'PLAYWRIGHT_STATUS'
  if (-not $pw) { return $false }

  if ($UiChanged) {
    # UI slices: real Playwright green + zero console/page errors + screenshot on disk.
    if ($pw -notmatch '^(?i)green$') { return $false }

    $console = Get-SliceVerifyMarker -Probe $probe -Name 'CONSOLE_ERRORS'
    $page = Get-SliceVerifyMarker -Probe $probe -Name 'PAGE_ERRORS'
    if ($null -eq $console -or $null -eq $page) { return $false }
    if ($console -notmatch '^\d+$' -or $page -notmatch '^\d+$') { return $false }
    if ([int]$console -ne 0 -or [int]$page -ne 0) { return $false }

    $path = $EvidencePath
    if (-not $path -and ($Result.PSObject.Properties.Name -contains 'EvidencePath')) {
      $path = [string]$Result.EvidencePath
    }
    if (-not $path) { return $false }
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    try {
      $len = (Get-Item -LiteralPath $path).Length
      if ($len -lt 64) { return $false } # empty / stub file
    } catch { return $false }
  } else {
    # Non-UI: may skip Playwright, or report green. Red is always red.
    if ($pw -match '^(?i)red$') { return $false }
    if ($pw -notmatch '^(?i)(green|skipped-non-ui)$') { return $false }
  }

  return $true
}
