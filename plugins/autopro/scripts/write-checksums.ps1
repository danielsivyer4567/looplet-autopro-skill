#Requires -Version 7.0
<#
  write-checksums.ps1 — SHA256SUMS for trust review / release pins.

  Usage (from package root):
    pwsh -NoProfile -File plugins/autopro/scripts/write-checksums.ps1

  Writes SHA256SUMS.txt at package root (paths relative to package root).
#>
param(
  [string]$PackageRoot = '',
  [string]$OutFile = ''
)

$ErrorActionPreference = 'Stop'
if (-not $PackageRoot) {
  # scripts/ is under plugins/autopro/scripts → package root is ../../..
  $PackageRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
}
if (-not $OutFile) { $OutFile = Join-Path $PackageRoot 'SHA256SUMS.txt' }

$skill = Join-Path $PackageRoot 'plugins\autopro'
if (-not (Test-Path (Join-Path $skill 'SKILL.md'))) {
  throw "No plugins/autopro/SKILL.md under $PackageRoot"
}

$include = @(
  'plugins/autopro/SKILL.md',
  'plugins/autopro/scripts/launch-autopro.ps1',
  'plugins/autopro/scripts/launch-showtime.ps1',
  'plugins/autopro/scripts/autopro-runner.ps1',
  'plugins/autopro/scripts/theater-server.mjs',
  'plugins/autopro/scripts/join-alarm-loud.ps1',
  'plugins/autopro/scripts/showtime-open-board.ps1',
  'plugins/autopro/scripts/showtime-final-check.ps1',
  'plugins/autopro/theater/index.html',
  'install.ps1',
  'install.sh',
  'get.ps1',
  'get.sh',
  'VERSION'
)

$lines = [System.Collections.Generic.List[string]]::new()
foreach ($rel in $include) {
  $full = Join-Path $PackageRoot ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)
  if (-not (Test-Path -LiteralPath $full)) {
    Write-Warning "skip missing $rel"
    continue
  }
  $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
  $lines.Add(("{0}  {1}" -f $hash, ($rel -replace '\\', '/')))
}

$header = @(
  "# AutoPro package checksums (SHA-256)"
  "# Generated: $((Get-Date).ToUniversalTime().ToString('o'))"
  "# Package root: $PackageRoot"
  "# Verify: Get-FileHash -Algorithm SHA256 <file>"
  ""
)
($header + $lines) | Set-Content -LiteralPath $OutFile -Encoding utf8
Write-Output "WROTE=$OutFile"
Write-Output ("COUNT={0}" -f $lines.Count)
$lines | ForEach-Object { Write-Output $_ }
