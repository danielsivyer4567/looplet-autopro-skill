<#
  get.ps1 — convenience remote bootstrap for Windows / PowerShell 7.

  ⚠  REMOTE CODE EXECUTION. Running this pipes GitHub master into your shell.
     Prefer the trusted path (inspect, then install):

       git clone https://github.com/danielsivyer4567/looplet-autopro-skill.git
       cd looplet-autopro-skill
       # read install.ps1 + TRUST.md + VERSION
       pwsh -NoProfile -File install.ps1

  Convenience (you already trust this repo):

       irm https://raw.githubusercontent.com/danielsivyer4567/looplet-autopro-skill/master/get.ps1 | iex

  Optional pin (safer than floating master):

       $env:AUTOPRO_REF = 'v1.1.1'   # tag or full commit SHA
       irm …/get.ps1 | iex

  What this script does (and only this):
    1. Download GitHub archive for AUTOPRO_REF (default: master branch)
    2. Run install.ps1 from that archive (copy + backup; no extra network hooks)

  See TRUST.md / README.md for checksums, dry-run, rollback.
#>
$ErrorActionPreference = 'Stop'
$owner = 'danielsivyer4567'
$repo = 'looplet-autopro-skill'
# Pin with env: full SHA, tag (e.g. v1.1.1), or branch name
$ref = if ($env:AUTOPRO_REF) { $env:AUTOPRO_REF.Trim() } else { 'master' }

Write-Host ''
Write-Host 'AutoPro get.ps1 — CONVENIENCE INSTALL (remote bootstrap)' -ForegroundColor Yellow
Write-Host 'This downloads and executes code from GitHub. Preferred: clone + install.ps1 (see TRUST.md).'
Write-Host ("REF={0}" -f $ref)
Write-Host ''

# Branch vs commit/tag: GitHub archive URLs differ slightly
if ($ref -eq 'master' -or $ref -eq 'main') {
  $zipUrl = "https://github.com/$owner/$repo/archive/refs/heads/$ref.zip"
} elseif ($ref -match '^[0-9a-f]{7,40}$') {
  $zipUrl = "https://github.com/$owner/$repo/archive/$ref.zip"
} else {
  # tag or other ref name
  $zipUrl = "https://github.com/$owner/$repo/archive/refs/tags/$ref.zip"
  # fallback try heads if tags 404 later
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("autopro-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  Write-Host "AutoPro: downloading $zipUrl …"
  $zip = Join-Path $tmp 'src.zip'
  try {
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing
  } catch {
    if ($ref -ne 'master' -and $ref -notmatch '^[0-9a-f]{7,40}$') {
      $zipUrl = "https://github.com/$owner/$repo/archive/refs/heads/$ref.zip"
      Write-Host "retry heads: $zipUrl"
      Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing
    } else { throw }
  }
  Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
  $src = Get-ChildItem -LiteralPath $tmp -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'install.ps1') } | Select-Object -First 1
  if (-not $src) { throw 'downloaded archive did not contain install.ps1' }
  $verPath = Join-Path $src.FullName 'VERSION'
  if (Test-Path -LiteralPath $verPath) {
    Write-Host ("package VERSION={0}" -f (Get-Content -LiteralPath $verPath -Raw).Trim())
  }
  & (Join-Path $src.FullName 'install.ps1')
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
