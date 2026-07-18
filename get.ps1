<#
  get.ps1 — AutoPro one-line web installer for Windows / PowerShell 7.

  Run this (nothing to clone, nothing to cd into):

      irm https://raw.githubusercontent.com/danielsivyer4567/looplet-autopro-skill/master/get.ps1 | iex

  It downloads the skill, installs it to $HOME/.claude/skills/autopro (backing up any existing
  copy), and confirms pwsh. Then type /autopro in Claude Code.
#>
$ErrorActionPreference = 'Stop'
$owner = 'danielsivyer4567'; $repo = 'looplet-autopro-skill'; $branch = 'master'
$zipUrl = "https://github.com/$owner/$repo/archive/refs/heads/$branch.zip"
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("autopro-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  Write-Host "AutoPro: downloading the skill…"
  $zip = Join-Path $tmp 'src.zip'
  Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing
  Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
  $src = Get-ChildItem -LiteralPath $tmp -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'install.ps1') } | Select-Object -First 1
  if (-not $src) { throw 'downloaded archive did not contain install.ps1' }
  & (Join-Path $src.FullName 'install.ps1')
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
