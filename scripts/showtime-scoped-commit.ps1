<#
  showtime-scoped-commit.ps1 — commit ONLY inside a Show Time worktree.

  Never runs from the primary checkout. Stages only porcelain paths in this tree.
#>
param(
  [Parameter(Mandatory = $true)][string]$WorktreeDir,
  [string]$Message = '',
  [string]$SessionId = '',
  [string]$SliceId = ''
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $WorktreeDir)) { throw "Worktree missing: $WorktreeDir" }

# Refuse if this looks like someone passed the primary repo by accident without marker
$marker = Join-Path $WorktreeDir '.showtime-worktree.json'
if (-not (Test-Path -LiteralPath $marker)) {
  # Allow if path contains .worktrees-showtime
  if ($WorktreeDir -notmatch '\.worktrees-showtime') {
    throw "Refusing commit: $WorktreeDir is not a Show Time worktree (no .showtime-worktree.json)"
  }
}

Push-Location -LiteralPath $WorktreeDir
try {
  $status = & git status --porcelain
  if (-not "$status".Trim()) {
    Write-Output 'STATUS=nothing-to-commit'
    exit 0
  }

  # Stage only paths listed in porcelain (this worktree only)
  $paths = @()
  foreach ($line in $status) {
    if ($line.Length -lt 4) { continue }
    $p = $line.Substring(3).Trim().Trim('"')
    # renames: "old -> new"
    if ($p -match ' -> ') { $p = ($p -split ' -> ')[-1].Trim() }
    if (($p -replace '\\', '/') -eq '.showtime-worktree.json') { continue }
    if ($p) { $paths += $p }
  }
  $paths = $paths | Select-Object -Unique
  if (-not $paths.Count) {
    Write-Output 'STATUS=nothing-to-commit'
    exit 0
  }

  & git reset -- .showtime-worktree.json 2>&1 | Out-Null
  foreach ($p in $paths) {
    & git add -- $p 2>&1 | Out-Null
  }

  if (-not $Message) {
    $bits = @('showtime')
    if ($SessionId) { $bits += $SessionId.Substring(0, [Math]::Min(12, $SessionId.Length)) }
    if ($SliceId) { $bits += $SliceId }
    $Message = ($bits -join ': ') + ' — scoped worktree commit'
  }

  & git commit -m $Message 2>&1 | ForEach-Object { Write-Output "commit> $_" }
  if ($LASTEXITCODE -ne 0) { throw 'commit failed' }

  $hash = (& git rev-parse --short HEAD).Trim()
  Write-Output "STATUS=committed"
  Write-Output "COMMIT=$hash"
  Write-Output "FILES=$($paths.Count)"
} finally {
  Pop-Location
}
