# ultra-band-lib.ps1 — pure band math + ledger helpers for boring-safe parallel autopro
# Dot-source from launch-ultra.ps1 / autopro-ultra.ps1

function Get-EvenBandSizes {
  param([int]$N, [int]$S = 5)
  if ($N -le 0) { return @() }
  if ($S -lt 1) { $S = 1 }
  $K = [math]::Ceiling($N / [double]$S)
  $q = [math]::Floor($N / $K)
  $r = $N % $K
  $sizes = @()
  for ($i = 0; $i -lt $K; $i++) {
    $sizes += ($q + $(if ($i -lt $r) { 1 } else { 0 }))
  }
  return $sizes
}

function Get-PackBandSizes {
  param([int]$N, [int]$S = 5)
  if ($N -le 0) { return @() }
  if ($S -lt 1) { $S = 1 }
  $K = [math]::Ceiling($N / [double]$S)
  if ($K -eq 1) { return @($N) }
  $sizes = @()
  for ($i = 0; $i -lt ($K - 1); $i++) { $sizes += $S }
  $sizes += ($N - $S * ($K - 1))
  return $sizes
}

function Get-UltraBandPlan {
  param(
    [string[]]$ScIds,
    [int]$BandSize = 5,
    [ValidateSet('even', 'pack')][string]$SplitMode = 'even'
  )
  $N = $ScIds.Count
  $sizes = if ($SplitMode -eq 'pack') {
    Get-PackBandSizes -N $N -S $BandSize
  } else {
    Get-EvenBandSizes -N $N -S $BandSize
  }
  $bands = @()
  $start = 0
  for ($i = 0; $i -lt $sizes.Count; $i++) {
    $sz = [int]$sizes[$i]
    $slice = @()
    if ($sz -gt 0 -and $start -lt $N) {
      $end = [math]::Min($start + $sz - 1, $N - 1)
      $slice = @($ScIds[$start..$end])
    }
    $bands += [pscustomobject]@{
      BandId = ('B{0:D2}' -f ($i + 1))
      Index  = $i
      ScIds  = $slice
      Size   = $slice.Count
    }
    $start += $sz
  }
  return $bands
}

function Get-LedgerSliceRows {
  param([string]$LedgerPath)
  if (-not (Test-Path -LiteralPath $LedgerPath)) { return @() }
  $rows = @()
  $i = 0
  foreach ($line in (Get-Content -LiteralPath $LedgerPath)) {
    $i++
    # SC-07, SC-DRY-01, SC-12a, etc.
    if ($line -match '^##\s+(SC-[\w-]+)\s+[—\-]\s+(.+?)\s+\[(pending|in-progress|done|blocked)\]\s*$') {
      $rows += [pscustomobject]@{
        LineNo = $i
        Id     = $Matches[1]
        Title  = $Matches[2].Trim()
        State  = $Matches[3]
        Raw    = $line
      }
    }
  }
  return $rows
}

function Get-RunnableScIds {
  param(
    [string]$LedgerPath,
    [switch]$IncludeBlockedPaused
  )
  $rows = Get-LedgerSliceRows -LedgerPath $LedgerPath
  $out = @()
  # Dedup by id (preserve first-occurrence order). A duplicated SC header —
  # copy-paste, a re-added slice, a typo'd id — would otherwise land the SAME
  # id in two different bands, and both worktrees would implement it in
  # parallel (a genuine claim-overlap). One id → at most one band.
  $seen = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($r in $rows) {
    $runnable = ($r.State -eq 'pending' -or $r.State -eq 'in-progress') -or
      ($IncludeBlockedPaused -and $r.State -eq 'blocked')
    if ($runnable -and $seen.Add($r.Id)) { $out += $r.Id }
  }
  return $out
}

function Set-LedgerSliceStates {
  param(
    [string]$LedgerPath,
    [hashtable]$IdToState,  # SC-07 -> pending
    [string]$Note = ''
  )
  $raw = Get-Content -LiteralPath $LedgerPath -Raw
  foreach ($id in $IdToState.Keys) {
    $st = $IdToState[$id]
    $raw = [regex]::Replace(
      $raw,
      "(?m)^(##\s+$([regex]::Escape($id))\s+[—\-]\s+.+?)\s+\[(pending|in-progress|done|blocked)\]\s*$",
      { param($m) "$($m.Groups[1].Value)  [$st]" }
    )
  }
  if ($Note -and $raw -notmatch [regex]::Escape($Note.Substring(0, [math]::Min(40, $Note.Length)))) {
    # optional stamp skipped if messy
  }
  # Atomic write: a truncate-then-write (WriteAllText) can leave the ledger —
  # the of-record file — half-written or empty if the process is killed mid-write
  # (ultra kills stalled workers with Stop-ProcessTree). Write a sibling temp on
  # the same volume, then rename over the target (an atomic replace on Windows).
  $tmp = "$LedgerPath.tmp.$PID"
  [System.IO.File]::WriteAllText($tmp, $raw)
  [System.IO.File]::Move($tmp, $LedgerPath, $true)
}

# Canonical band-result decode — shared by autopro-ultra.ps1 AND ultra-resume.ps1
# so "done" means exactly one thing (two divergent copies previously disagreed
# on whether a missing bandId or a string "ok" counted as done). Fail-closed.
function Test-BandResultOk([string]$Worktree, [string]$BandId) {
  $p = Join-Path $Worktree '.claude/scratch/band-result.json'
  if (-not (Test-Path -LiteralPath $p)) { return $false }
  try {
    $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    if (-not $j) { return $false }
    # bandId, when present, must match — never accept another band's result.
    if ($j.bandId -and [string]$j.bandId -ne $BandId) { return $false }
    if ($j.PSObject.Properties.Name -contains 'ok') {
      # [bool]'false' is $true in PowerShell — parse a string "ok" fail-closed.
      if ($j.ok -is [bool]) { return [bool]$j.ok }
      $s = ([string]$j.ok).Trim().ToLowerInvariant()
      return ($s -eq 'true' -or $s -eq '1' -or $s -eq 'yes')
    }
    if ($j.done) { return $true }
    return $false
  } catch { return $false }
}

# The SCs a band actually finished, intersected with what it was CLAIMED to own.
# Returned to the orchestrator so it — the single master writer — can reconcile
# the master ledger. Never returns an SC the band did not claim.
function Get-BandDoneScIds([string]$Worktree, [string[]]$ClaimedScIds) {
  $p = Join-Path $Worktree '.claude/scratch/band-result.json'
  if (-not (Test-Path -LiteralPath $p)) { return @() }
  try {
    $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    if (-not $j -or -not $j.done) { return @() }
    $claim = [System.Collections.Generic.HashSet[string]]::new([string[]]@($ClaimedScIds))
    $out = @()
    foreach ($id in @($j.done)) {
      $sid = ([string]$id).Trim()
      if ($sid -and $claim.Contains($sid)) { $out += $sid }
    }
    return $out
  } catch { return @() }
}

function Set-LedgerUnblockAllBlocked {
  param([string]$LedgerPath)
  $raw = Get-Content -LiteralPath $LedgerPath -Raw
  # Match the SAME id class the parser + band-ledger rewrite use (SC-[\w-]+ —
  # e.g. SC-DRY-01, SC-12a). SC-\d+ silently left alpha/suffixed ids [blocked],
  # so -UnblockPaused would drop them from the runnable set with no warning.
  $raw = [regex]::Replace(
    $raw,
    '(?m)^(##\s+SC-[\w-]+\s+[—\-]\s+.+?)\s+\[blocked\]\s*$',
    { param($m) $m.Groups[1].Value + '  [pending]' }
  )
  # clear PAUSE line noise if present
  $raw = $raw -replace '(?m)^PAUSE:.*\r?\n', ''
  [System.IO.File]::WriteAllText($LedgerPath, $raw)
}

function Get-StartsAfterLabel {
  param(
    [int]$BandIndex,
    [int]$MaxConcurrency,
    [object[]]$Bands
  )
  if ($BandIndex -lt $MaxConcurrency) { return $null }
  $pred = $BandIndex - $MaxConcurrency
  if ($pred -ge 0 -and $pred -lt $Bands.Count) {
    return "starts after $($Bands[$pred].BandId) finishes"
  }
  return "starts after an earlier band finishes"
}

# SC-id → human task title from ledger headers (for board cards).
function Get-LedgerTitleMap {
  param([string]$LedgerPath)
  $map = @{}
  if (-not (Test-Path -LiteralPath $LedgerPath)) { return $map }
  foreach ($line in (Get-Content -LiteralPath $LedgerPath)) {
    if ($line -match '^##\s+(SC-[\w-]+)\s+[—\-]\s+(.+?)\s+\[(pending|in-progress|done|blocked)\]') {
      $map[$Matches[1]] = $Matches[2].Trim()
    }
  }
  return $map
}

function Get-ScDisplayText {
  param(
    [string]$ScId,
    [hashtable]$TitleMap,
    [switch]$WithId
  )
  $title = $null
  if ($TitleMap -and $TitleMap.ContainsKey($ScId)) { $title = [string]$TitleMap[$ScId] }
  if (-not $title) { return $ScId }
  # Board cards already show id in the pill — default text is the human task only.
  if ($WithId) { return "$ScId — $title" }
  return $title
}

# Build SA-lane todos from a band's own ledger (states + titles). Falls back to pending.
function Get-BandTodosForBoard {
  param(
    [string[]]$ScIds,
    [string]$BandLedgerPath = '',
    [string]$MasterLedgerPath = '',
    [bool]$Alive = $false,
    [string]$BandState = 'queued'
  )
  $titleMap = @{}
  if ($MasterLedgerPath) {
    $titleMap = Get-LedgerTitleMap -LedgerPath $MasterLedgerPath
  }
  $stateById = @{}
  $ledgerForStates = if ($BandLedgerPath -and (Test-Path -LiteralPath $BandLedgerPath)) {
    $BandLedgerPath
  } elseif ($MasterLedgerPath -and (Test-Path -LiteralPath $MasterLedgerPath)) {
    $MasterLedgerPath
  } else { '' }
  if ($ledgerForStates) {
    foreach ($r in (Get-LedgerSliceRows -LedgerPath $ledgerForStates)) {
      $stateById[$r.Id] = $r.State
      if (-not $titleMap.ContainsKey($r.Id) -and $r.Title) { $titleMap[$r.Id] = $r.Title }
    }
  }

  # Prefer first in-progress among band SCs; else first pending; else first id.
  $activeId = $null
  foreach ($id in $ScIds) {
    if ($stateById.ContainsKey($id) -and $stateById[$id] -eq 'in-progress') { $activeId = $id; break }
  }
  if (-not $activeId) {
    foreach ($id in $ScIds) {
      $st = if ($stateById.ContainsKey($id)) { $stateById[$id] } else { 'pending' }
      if ($st -eq 'pending') { $activeId = $id; break }
    }
  }
  if (-not $activeId -and $ScIds.Count) { $activeId = [string]$ScIds[0] }

  $todo = @()
  foreach ($id in $ScIds) {
    $sid = [string]$id
    $fromLedger = if ($stateById.ContainsKey($sid)) { $stateById[$sid] } else { $null }
    $st = if ($BandState -eq 'done') { 'done' }
      elseif ($fromLedger -eq 'done') { 'done' }
      elseif ($BandState -match 'fail|stall') { 'blocked' }
      elseif ($Alive -and $sid -eq $activeId) { 'in-progress' }
      elseif ($fromLedger -eq 'in-progress' -and $Alive) { 'in-progress' }
      elseif ($fromLedger -eq 'blocked' -and -not $Alive) { 'blocked' }
      else { 'pending' }
    $todo += @{
      id    = $sid
      text  = (Get-ScDisplayText -ScId $sid -TitleMap $titleMap)
      state = $st
    }
  }
  return [pscustomobject]@{
    Todo     = $todo
    ActiveId = $activeId
    TitleMap = $titleMap
  }
}

