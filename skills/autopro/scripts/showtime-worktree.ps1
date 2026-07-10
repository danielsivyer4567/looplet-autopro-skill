<#
  showtime-worktree.ps1 — per-chat git worktree isolation for Show Time / autopro.

  Actions:
    create   - create branch + worktree for a session
    path     - print worktree path if it exists
    finish   - merge session branch into base, then prune worktree + branch
    prune    - remove READY worktrees (merged or stale + clean)
    list     - list showtime worktrees

  Isolation rule: each Chat/session owns one worktree. Commits never run in
  the primary dirty tree, so concurrent chats cannot drag each other in.
#>
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('create', 'path', 'finish', 'prune', 'list')]
  [string]$Action,

  [string]$RepoDir = '',
  [string]$SessionId = '',
  [string]$BaseBranch = '',
  [string]$LedgerHash = '',
  [string]$LedgerTitle = '',
  # Where session branches land on finish:
  #   base  = merge into the branch you armed from (default; all mini-branches rejoin one epic line)
  #   main  = each ledger/session merges into main (or master) after check
  [ValidateSet('base', 'main')]
  [string]$MergeTarget = 'base',
  [string]$MainBranch = '',  # optional override when MergeTarget=main (default: main, else master)
  [switch]$Push,
  [switch]$ForcePruneStale,
  [int]$StaleDays = 7
)

$ErrorActionPreference = 'Stop'

function Assert-GitRepo([string]$dir) {
  if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { throw "RepoDir not found: $dir" }
  Push-Location -LiteralPath $dir
  try {
    $inside = & git rev-parse --is-inside-work-tree 2>$null
    if ("$inside".Trim() -ne 'true') { throw "Not a git repo: $dir" }
  } finally { Pop-Location }
}

function Get-PrimaryRoot([string]$dir) {
  Push-Location -LiteralPath $dir
  try {
    # Prefer common git dir's parent worktree list first entry
    $top = (& git rev-parse --show-toplevel 2>$null).Trim()
    return $top
  } finally { Pop-Location }
}

function Get-WorktreeRoot([string]$primary) {
  # Sibling folder next to primary: <parent>/.worktrees-showtime/<session>
  # Avoid nesting worktrees inside the repo (cleaner prune).
  $parent = Split-Path $primary -Parent
  $root = Join-Path $parent '.worktrees-showtime'
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return $root
}

function Get-BranchName([string]$sessionId) {
  $safe = ($sessionId -replace '[^a-zA-Z0-9._-]', '_').ToLowerInvariant()
  if (-not $safe) { $safe = 'anon' }
  return "showtime/$safe"
}

function Get-WorktreePath([string]$primary, [string]$sessionId) {
  $root = Get-WorktreeRoot $primary
  $safe = ($sessionId -replace '[^a-zA-Z0-9._-]', '_').ToLowerInvariant()
  return (Join-Path $root $safe)
}

function Get-CurrentBranch([string]$dir) {
  Push-Location -LiteralPath $dir
  try {
    $b = (& git rev-parse --abbrev-ref HEAD 2>$null).Trim()
    if ($b -eq 'HEAD' -or -not $b) { return 'main' }
    return $b
  } finally { Pop-Location }
}

function Resolve-MainBranch([string]$dir, [string]$preferred) {
  Push-Location -LiteralPath $dir
  try {
    foreach ($cand in @($preferred, 'main', 'master')) {
      if (-not $cand) { continue }
      & git rev-parse --verify $cand 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { return $cand }
      & git rev-parse --verify "origin/$cand" 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) { return $cand }
    }
    return 'main'
  } finally { Pop-Location }
}

function Resolve-MergeInto([string]$primary, [string]$baseFromMeta, [string]$target, [string]$mainPref) {
  if ($target -eq 'main') {
    return (Resolve-MainBranch $primary $mainPref)
  }
  if ($baseFromMeta) { return ($baseFromMeta -replace '^origin/', '') }
  return (Get-CurrentBranch $primary)
}

function Invoke-Git([string]$dir, [string[]]$GitArgs) {
  Push-Location -LiteralPath $dir
  try {
    & git @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE)"
    }
  } finally { Pop-Location }
}

function Restore-PrimaryBranch([string]$primary, [string]$branch) {
  # finish checks out the merge target in the operator's primary tree. Put it back.
  if (-not $branch) { return }
  Push-Location -LiteralPath $primary
  try {
    & git checkout $branch 2>&1 | ForEach-Object { Write-Output "git> $_" }
    if ($LASTEXITCODE -eq 0) { Write-Output "RESTORED_BRANCH=$branch" }
    else { Write-Output "RESTORE_BRANCH_FAILED=$branch" }
  } finally { Pop-Location }
}

switch ($Action) {
  'list' {
    if (-not $RepoDir) { throw 'RepoDir required' }
    Assert-GitRepo $RepoDir
    $primary = Get-PrimaryRoot $RepoDir
    Push-Location $primary
    try {
      $raw = & git worktree list --porcelain
      $blocks = ($raw -join "`n") -split '(?=path )'
      foreach ($b in $blocks) {
        if ($b -match 'path (.+)' -and $b -match 'branch refs/heads/(showtime/.+)') {
          Write-Output ("{0}`t{1}" -f $Matches[1].Trim(), $Matches[2].Trim())
        } elseif ($b -match 'path (.+[\\/]\.worktrees-showtime[\\/].+)') {
          Write-Output ("{0}`t(detached-or-unparsed)" -f $Matches[1].Trim())
        }
      }
    } finally { Pop-Location }
  }

  'path' {
    if (-not $RepoDir -or -not $SessionId) { throw 'RepoDir + SessionId required' }
    $primary = Get-PrimaryRoot $RepoDir
    $wt = Get-WorktreePath $primary $SessionId
    if (Test-Path -LiteralPath $wt) { Write-Output $wt } else { Write-Output '' }
  }

  'create' {
    if (-not $RepoDir -or -not $SessionId) { throw 'RepoDir + SessionId required' }
    Assert-GitRepo $RepoDir
    $primary = Get-PrimaryRoot $RepoDir
    $wt = Get-WorktreePath $primary $SessionId
    $branch = Get-BranchName $SessionId
    if (-not $BaseBranch) { $BaseBranch = Get-CurrentBranch $primary }

    if (Test-Path -LiteralPath $wt) {
      Write-Output "WORKTREE_PATH=$wt"
      Write-Output "BRANCH=$branch"
      Write-Output "BASE=$BaseBranch"
      Write-Output 'STATUS=exists'
      break
    }

    Push-Location $primary
    try {
      # Ensure base exists
      $null = & git rev-parse --verify $BaseBranch 2>$null
      if ($LASTEXITCODE -ne 0) {
        $null = & git rev-parse --verify "origin/$BaseBranch" 2>$null
        if ($LASTEXITCODE -eq 0) { $BaseBranch = "origin/$BaseBranch" }
        else { $BaseBranch = 'HEAD' }
      }

      $branchExists = & git show-ref --verify --quiet "refs/heads/$branch"; $be = $LASTEXITCODE
      if ($be -eq 0) {
        & git worktree add $wt $branch 2>&1 | Out-Null
      } else {
        & git worktree add -b $branch $wt $BaseBranch 2>&1 | Out-Null
      }
      if ($LASTEXITCODE -ne 0) { throw "worktree add failed for $wt" }
    } finally { Pop-Location }

    # Marker for finish/prune
    $meta = @{
      sessionId   = $SessionId
      branch      = $branch
      baseBranch  = ($BaseBranch -replace '^origin/', '')
      ledgerHash  = $LedgerHash
      ledgerTitle = $LedgerTitle
      mergeTarget = $MergeTarget
      mainBranch  = $MainBranch
      primary     = $primary
      createdAt   = (Get-Date).ToUniversalTime().ToString('o')
    }
    $meta | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $wt '.showtime-worktree.json') -Encoding utf8

    Write-Output "WORKTREE_PATH=$wt"
    Write-Output "BRANCH=$branch"
    Write-Output "BASE=$BaseBranch"
    Write-Output "MERGE_TARGET=$MergeTarget"
    Write-Output 'STATUS=created'
  }

  'finish' {
    if (-not $RepoDir -or -not $SessionId) { throw 'RepoDir + SessionId required' }
    Assert-GitRepo $RepoDir
    $primary = Get-PrimaryRoot $RepoDir
    $wt = Get-WorktreePath $primary $SessionId
    $branch = Get-BranchName $SessionId
    $metaPath = Join-Path $wt '.showtime-worktree.json'
    $meta = $null
    $baseFromMeta = $BaseBranch
    $target = $MergeTarget
    $mainPref = $MainBranch
    if (Test-Path $metaPath) {
      $meta = Get-Content $metaPath -Raw | ConvertFrom-Json
      if (-not $baseFromMeta) { $baseFromMeta = $meta.baseBranch }
      # Param wins if caller passed explicit non-default; otherwise honor meta from arm
      if ($PSBoundParameters.ContainsKey('MergeTarget')) { $target = $MergeTarget }
      elseif ($meta.mergeTarget) { $target = $meta.mergeTarget }
      if (-not $mainPref -and $meta.mainBranch) { $mainPref = $meta.mainBranch }
    }
    $mergeInto = Resolve-MergeInto $primary $baseFromMeta $target $mainPref

    if (-not (Test-Path -LiteralPath $wt)) {
      Write-Output 'STATUS=no-worktree'
      break
    }

    # Require clean worktree (committed already)
    Push-Location $wt
    try {
      $dirty = @(& git status --porcelain | Where-Object {
        $line = "$_"
        if ($line.Length -lt 4) { return $false }
        $p = $line.Substring(3).Trim().Trim('"')
        if ($p -match ' -> ') { $p = ($p -split ' -> ')[-1].Trim() }
        (($p -replace '\\', '/') -ne '.showtime-worktree.json')
      })
      if ("$dirty".Trim()) {
        Write-Output 'STATUS=dirty'
        Write-Output 'HINT=Commit or stash inside the worktree before finish/merge'
        exit 2
      }
    } finally { Pop-Location }

    # Optional push of session branch
    if ($Push) {
      Push-Location $wt
      try {
        & git push -u origin "HEAD:refs/heads/$branch" 2>&1 | ForEach-Object { Write-Output "push> $_" }
      } catch {
        Write-Output "push> warn: $($_.Exception.Message)"
      } finally { Pop-Location }
    }

    # Merge into chosen target on primary (does not touch other worktrees' files)
    Write-Output "MERGE_TARGET=$target"
    Write-Output "MERGING_INTO=$mergeInto"
    $switched = $false
    $restoreTo = ''
    Push-Location $primary
    try {
      $cur = Get-CurrentBranch $primary
      if ($cur -ne $mergeInto) {
        & git checkout $mergeInto 2>&1 | ForEach-Object { Write-Output "git> $_" }
        if ($LASTEXITCODE -ne 0) { throw "checkout $mergeInto failed" }
        $switched = $true
        $restoreTo = $cur
      }
      $msg = "showtime: merge $branch into $mergeInto (session $SessionId, target=$target)"
      & git merge --no-ff $branch -m $msg 2>&1 | ForEach-Object { Write-Output "merge> $_" }
      if ($LASTEXITCODE -ne 0) {
        Write-Output 'STATUS=merge-conflict'
        Write-Output "HINT=Resolve merge on $mergeInto then re-run prune for $SessionId"
        # Deliberately not restored: the conflict must be resolved on $mergeInto.
        if ($switched) { Write-Output "PRIMARY_LEFT_ON=$mergeInto (after resolving: git checkout $restoreTo)" }
        exit 3
      }
      $mergeCommit = (& git rev-parse --short HEAD 2>$null).Trim()
      if ($mergeCommit) { Write-Output "MERGE_COMMIT=$mergeCommit" }
    } finally { Pop-Location }

    # Prune worktree + branch
    Push-Location $primary
    try {
      & git worktree remove --force $wt 2>&1 | ForEach-Object { Write-Output "wt> $_" }
      $wtRemoveExit = $LASTEXITCODE
      & git branch -d $branch 2>&1 | ForEach-Object { Write-Output "branch> $_" }
      $branchDeleteExit = $LASTEXITCODE
      & git worktree prune 2>&1 | Out-Null
      if ($wtRemoveExit -ne 0 -or (Test-Path -LiteralPath $wt)) {
        Write-Output 'STATUS=worktree-remove-failed'
        Write-Output "WORKTREE_PATH=$wt"
        # Merge already landed; hand the operator's branch back before bailing.
        if ($switched) { Restore-PrimaryBranch $primary $restoreTo }
        exit 4
      }
      if ($branchDeleteExit -ne 0) {
        Write-Output 'STATUS=branch-delete-failed'
        Write-Output "BRANCH=$branch"
        if ($switched) { Restore-PrimaryBranch $primary $restoreTo }
        exit 5
      }
    } finally { Pop-Location }

    if ($switched) { Restore-PrimaryBranch $primary $restoreTo }

    Write-Output "STATUS=merged-and-pruned"
    Write-Output "MERGED_INTO=$mergeInto"
    Write-Output "MERGE_TARGET=$target"
    Write-Output "BRANCH=$branch"
    Write-Output "WORKTREE_REMOVED=$wt"
  }

  'prune' {
    if (-not $RepoDir) { throw 'RepoDir required' }
    Assert-GitRepo $RepoDir
    $primary = Get-PrimaryRoot $RepoDir
    $wtRoot = Get-WorktreeRoot $primary
    $cutoff = (Get-Date).AddDays(-1 * [Math]::Max(1, $StaleDays))

    Push-Location $primary
    try {
      $null = & git fetch --prune 2>$null
      $list = & git worktree list --porcelain
      $entries = @()
      $cur = @{}
      foreach ($line in $list) {
        if ($line -match '^path (.+)$') { if ($cur.path) { $entries += [pscustomobject]$cur }; $cur = @{ path = $Matches[1].Trim() } }
        elseif ($line -match '^branch refs/heads/(.+)$') { $cur.branch = $Matches[1].Trim() }
        elseif ($line -match '^HEAD (.+)$') { $cur.head = $Matches[1].Trim() }
      }
      if ($cur.path) { $entries += [pscustomobject]$cur }

      foreach ($e in $entries) {
        if ($e.path -notmatch '[\\/]\.worktrees-showtime[\\/]') { continue }
        if (-not $e.branch -or $e.branch -notmatch '^showtime/') { continue }

        $dirty = & git -C $e.path status --porcelain 2>$null
        $isDirty = [bool]"$dirty".Trim()
        $merged = $false
        & git merge-base --is-ancestor $e.branch HEAD 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $merged = $true }

        $stale = $false
        $metaFile = Join-Path $e.path '.showtime-worktree.json'
        if (Test-Path $metaFile) {
          try {
            $m = Get-Content $metaFile -Raw | ConvertFrom-Json
            $created = [datetime]::Parse($m.createdAt)
            if ($created -lt $cutoff) { $stale = $true }
          } catch {}
        }

        $ready = $false
        $reason = ''
        if ($merged -and -not $isDirty) { $ready = $true; $reason = 'merged' }
        elseif ($ForcePruneStale -and $stale -and -not $isDirty) { $ready = $true; $reason = 'stale-clean' }
        elseif ($isDirty) { Write-Output "SKIP dirty $($e.path)"; continue }
        else { Write-Output "SKIP waiting $($e.branch)"; continue }

        if ($ready) {
          Write-Output "PRUNE $reason $($e.branch) @ $($e.path)"
          & git worktree remove --force $e.path 2>&1 | ForEach-Object { Write-Output "  $_" }
          & git branch -d $e.branch 2>&1 | ForEach-Object { Write-Output "  $_" }
        }
      }
      & git worktree prune 2>&1 | Out-Null
      Write-Output 'STATUS=prune-done'
    } finally { Pop-Location }
  }
}
