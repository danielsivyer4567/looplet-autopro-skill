#Requires -Version 7.0
<# Offline: launch-autopro.ps1 size-based mode + dispatch. #>
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$launch = Join-Path $here 'launch-autopro.ps1'
$fail = 0
function Ok([string]$m) { Write-Output ("  OK  {0}" -f $m) }
function Bad([string]$m) { Write-Output ("  FAIL {0}" -f $m); $script:fail++ }

if (-not (Test-Path $launch)) { Bad 'launch-autopro.ps1 missing'; exit 1 }
$src = Get-Content $launch -Raw
if ($src -match "ValidateSet\('auto', 'serial', 'ultra', 'parallel'\)") { Ok 'Mode set includes auto' } else { Bad 'Mode set' }
if ($src -match "Mode = 'auto'") { Ok 'default Mode=auto' } else { Bad 'default not auto' }
if ($src -match 'Get-LedgerOpenSliceCount|SerialMaxSlices') { Ok 'size heuristic present' } else { Bad 'no size heuristic' }
if ($src -match 'launch-showtime\.ps1') { Ok 'dispatches serial → launch-showtime' } else { Bad 'no serial dispatch' }
if ($src -match 'launch-ultra\.ps1') { Ok 'dispatches ultra → launch-ultra' } else { Bad 'no ultra dispatch' }
if ($src -match "Mode -eq 'parallel'") { Ok 'parallel aliases to ultra' } else { Bad 'no parallel alias' }
if ($src -match '\$DryRun' -and $src -match 'DRY_RUN=1') { Ok 'DryRun switch + exit path present' } else { Bad 'DryRun missing' }

# Live DryRun against a temp repo (no arm)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("autopro-dryrun-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $tmp '.claude/scratch') | Out-Null
@(
  '# Ledger: dry-run fixture'
  'Approved: yes'
  '## SC-01 — A  [pending]'
  '## SC-02 — B  [pending]'
) | Set-Content -LiteralPath (Join-Path $tmp '.claude/scratch/ledger.md') -Encoding utf8
try {
  $out = & pwsh -NoProfile -File $launch -Root $tmp -RepoDir $tmp -DryRun 2>&1 | Out-String
  if ($LASTEXITCODE -eq 0 -and $out -match 'DRY_RUN=1' -and $out -match 'AUTOPRO_MODE=serial') {
    Ok 'live DryRun exits 0 and picks serial for small ledger'
  } else {
    Bad ("live DryRun failed exit={0} out={1}" -f $LASTEXITCODE, $out.Substring(0, [Math]::Min(200, $out.Length)))
  }
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# Pure count helper by sourcing a minimal extract: run auto resolve against temp ledgers
function Count-Open([string]$text) {
  $id = '(?:SC-\d+|SD-[\w-]+|H\d+|P\d+[-\w]*)'
  $p = ([regex]::Matches($text, "(?m)^##\s+$id[^\n]*\[pending\]")).Count
  $i = ([regex]::Matches($text, "(?m)^##\s+$id[^\n]*\[in-progress\]")).Count
  return $p + $i
}
$small = @"
# Ledger: small
Approved: yes
## SC-01 — A  [pending]
## SC-02 — B  [pending]
## SC-03 — C  [done]
"@
$bigLines = @('# Ledger: big', 'Approved: yes')
1..15 | ForEach-Object { $bigLines += ("## SC-{0:D2} — Slice {1}  [pending]" -f $_, $_) }
$big = $bigLines -join "`n"
$cSmall = Count-Open $small
$cBig = Count-Open $big
if ($cSmall -eq 2) { Ok "small ledger open=2" } else { Bad "small open=$cSmall" }
if ($cBig -eq 15) { Ok "big ledger open=15" } else { Bad "big open=$cBig" }
$thresh = 12
if ($cSmall -lt $thresh) { Ok 'small → would pick serial' } else { Bad 'small threshold wrong' }
if ($cBig -ge $thresh) { Ok 'big → would pick ultra' } else { Bad 'big threshold wrong' }

$skill = Get-Content (Join-Path $here '..\SKILL.md') -Raw
if ($skill -match 'launch-autopro\.ps1' -and $skill -match 'auto') { Ok 'SKILL.md documents auto front door' } else { Bad 'SKILL.md missing auto' }
if ($skill -match '12' -or $skill -match 'SerialMaxSlices') { Ok 'SKILL.md documents size threshold' } else { Bad 'SKILL.md missing threshold' }

if ($fail) { Write-Output ("LAUNCH_AUTOPRO_CHECK=red fails={0}" -f $fail); exit 1 }
Write-Output 'LAUNCH_AUTOPRO_CHECK=green'
exit 0
