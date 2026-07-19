# ultra-clean.ps1 — reclaim finished/old ultra worktrees (housing cleanup).
#
# Ultra creates one FULL git worktree checkout per band under
# <RepoDir>/.worktrees-ultra/<runId>/<BandId> and deliberately KEEPS them on
# stop (so no work is stranded). Across many epics that is unbounded disk.
# This command removes per-band worktrees and prunes stale admin entries.
#
# It never deletes branches (ref mutation is forbidden to ultra housing — see
# test-showtime.ps1's zero-git honesty scan) and never touches history. If you
# still need a band's commits, merge to integration BEFORE cleaning.
param(
  [Parameter(Mandatory = $true)][string]$RepoDir,
  [string]$RunId = '',        # a specific run; else every run under .worktrees-ultra
  [int]$OlderThanDays = 0,    # only runs whose dir is older than N days
  [switch]$OnlyComplete,      # only runs where every band has a band-result.json
  [switch]$WhatIf             # print what would be removed, change nothing
)

$ErrorActionPreference = 'Stop'
$RepoDir = (Resolve-Path -LiteralPath $RepoDir).Path
$wtBase = Join-Path $RepoDir '.worktrees-ultra'
if (-not (Test-Path -LiteralPath $wtBase)) {
  Write-Output "No .worktrees-ultra under $RepoDir — nothing to clean."
  exit 0
}

$runDirs = if ($RunId) {
  @(Join-Path $wtBase $RunId)
} else {
  @(Get-ChildItem -LiteralPath $wtBase -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}
$cutoff = if ($OlderThanDays -gt 0) { (Get-Date).AddDays(-$OlderThanDays) } else { $null }

$removed = 0
foreach ($rd in $runDirs) {
  if (-not (Test-Path -LiteralPath $rd)) { continue }
  if ($cutoff) {
    $mt = (Get-Item -LiteralPath $rd).LastWriteTime
    if ($mt -gt $cutoff) { Write-Output "SKIP (recent) $rd"; continue }
  }
  $bandDirs = @(Get-ChildItem -LiteralPath $rd -Directory -ErrorAction SilentlyContinue)
  if ($OnlyComplete) {
    $allDone = $true
    foreach ($bd in $bandDirs) {
      if (-not (Test-Path -LiteralPath (Join-Path $bd.FullName '.claude/scratch/band-result.json'))) { $allDone = $false; break }
    }
    if (-not $allDone) { Write-Output "SKIP (incomplete) $rd"; continue }
  }
  foreach ($bd in $bandDirs) {
    $path = $bd.FullName
    if ($WhatIf) { Write-Output "WOULD remove worktree $path"; continue }
    Push-Location $RepoDir
    try { git worktree remove --force $path 2>$null | Out-Null } catch {} finally { Pop-Location }
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
    $removed++
    Write-Output "REMOVED worktree $path"
  }
  if (-not $WhatIf) { Remove-Item -LiteralPath $rd -Recurse -Force -ErrorAction SilentlyContinue }
}

# Clear stale worktree admin entries left under .git/worktrees/.
Push-Location $RepoDir
try { git worktree prune 2>$null | Out-Null } catch {} finally { Pop-Location }

Write-Output "ULTRA_CLEAN removed=$removed whatIf=$([bool]$WhatIf)"
Write-Output 'Note: ultra/* branches are left intact (housing never deletes refs). Remove manually if unwanted: git branch -D ultra/<runId>-<BandId>'
