<#
  test-crossos.ps1 — proof for the cross-OS port that is runnable on EITHER OS.

  What it proves here on Windows:
    • the process helpers work on real pids (enumerate / by-id / detached-spawn / tree-kill);
    • the worker-engines resolvers, when FORCED into their Unix branch, run without throwing the
      null-`Join-Path` that used to crash on Unix, and still resolve a CLI via PATH;
    • the `($env:USERPROFILE ?? $HOME)` home-resolution falls back to $HOME when USERPROFILE is unset
      (the Unix condition);
    • the source no longer contains functional backslash paths or an unguarded $env:USERPROFILE.

  What it CANNOT prove on Windows (needs a real macOS/Linux run — called out, not faked):
    • the `ps -axww` enumeration parse, the leaves-first Stop-Process tree walk, and the `nohup`
      detached spawn — those Unix branches only execute on Unix.
#>
$ErrorActionPreference = 'Stop'
$Scripts = $PSScriptRoot
$fail = 0
function Ok([string]$m) { Write-Output "PASS  $m" }
function Bad([string]$m) { Write-Output "FAIL  $m"; $script:fail++ }

. (Join-Path $Scripts 'proc-crossos.ps1')
. (Join-Path $Scripts 'worker-engines.ps1')

$onWin = ($null -eq $IsWindows) -or $IsWindows
Write-Output ("HOST_OS={0}" -f ($(if ($onWin) { 'windows' } else { 'unix' })))
Write-Output '==== cross-OS port proof ===='

# ---- 1) process helpers on real pids (native to whichever OS runs this) ----
$self = Get-AutoproProcessById -Id $PID
if ($self -and $self.ProcessId -eq $PID) { Ok 'proc: Get-AutoproProcessById returns self' } else { Bad 'proc: by-id self lookup' }
$listed = @(Get-AutoproProcessList | Where-Object { $_.ProcessId -eq $PID }).Count -gt 0
if ($listed) { Ok 'proc: Get-AutoproProcessList includes self' } else { Bad 'proc: enum includes self' }

$sleeper = if ($onWin) { '"{0}" -NoProfile -Command "Start-Sleep -Seconds 30"' -f (Get-Command pwsh).Source }
           else { 'sleep 30' }
$sp = Start-DetachedProcess -CommandLine $sleeper -CurrentDirectory (Split-Path $Scripts -Parent)
if ($sp.ReturnValue -eq 0 -and $sp.ProcessId -gt 0) { Ok ("proc: Start-DetachedProcess ({0}) pid={1}" -f $sp.How, $sp.ProcessId) } else { Bad 'proc: detached spawn' }
Start-Sleep -Milliseconds 700
$killed = Stop-ProcessTree -Id $sp.ProcessId
Start-Sleep -Milliseconds 400
$gone = -not (Get-Process -Id $sp.ProcessId -ErrorAction SilentlyContinue)
if ($killed -and $gone) { Ok 'proc: Stop-ProcessTree removed the spawned tree' } else { Bad 'proc: tree kill' }

# ---- 2) worker-engines FORCED into the Unix branch (the null-Join-Path crash regression) ----
$savedFlag = $script:AutoproEnginesOnWindows
try {
  $script:AutoproEnginesOnWindows = $false   # pretend we are on Unix
  $threw = $false
  try {
    $node = Get-NodeExe                       # Unix branch: PATH lookup, no null Join-Path
    [void](Resolve-ClaudeExe)                 # each must return string-or-$null, never throw
    [void](Resolve-GrokExe)
    [void](Resolve-OllamaExe)
    [void](Resolve-NpmPackageJs -Package '@openai/codex' -RelativeBin 'bin/codex.js')
  } catch { $threw = $true; Write-Output ("   unix-branch threw: {0}" -f $_.Exception.Message) }
  if (-not $threw) { Ok 'engines(unix): resolvers run without the null-Join-Path throw' } else { Bad 'engines(unix): a resolver threw' }
  # node is on PATH on this box → the Unix PATH lookup should find it (proves resolution, not just no-throw)
  if ($node) { Ok ("engines(unix): Get-NodeExe resolved via PATH -> {0}" -f $node) } else { Bad 'engines(unix): PATH node not resolved' }
} finally {
  $script:AutoproEnginesOnWindows = $savedFlag
}

# ---- 3) home resolution falls back to $HOME when USERPROFILE is unset (the Unix condition) ----
$savedUP = $env:USERPROFILE
try {
  $env:USERPROFILE = $null
  $resolved = ($env:USERPROFILE ?? $HOME)
  if ($resolved -and $resolved -eq $HOME) { Ok 'home: ($env:USERPROFILE ?? $HOME) falls back to $HOME' } else { Bad 'home: coalesce fallback' }
} finally {
  $env:USERPROFILE = $savedUP
}
# When USERPROFILE IS set (Windows), the coalesce must be a no-op — identical to before the port.
# When it's unset (Unix), that invariant doesn't apply; the fallback is covered by the check above.
if ($env:USERPROFILE) {
  if ((($env:USERPROFILE ?? $HOME)) -eq $env:USERPROFILE) { Ok 'home: USERPROFILE set → coalesce is a no-op (Windows unchanged)' } else { Bad 'home: coalesce no-op broken' }
} else {
  Ok 'home: USERPROFILE unset on this OS → coalesce yields $HOME (Unix, correct)'
}

# ---- 4) source hygiene: no functional backslash paths, no unguarded USERPROFILE in core ----
$core = 'launch-showtime.ps1','autopro-runner.ps1','theater-register.ps1','autopro-status.ps1',
        'stop-autopro.ps1','launch-ultra.ps1','showtime-status.ps1','showtime-board-gate.ps1','autopro-ultra.ps1'
$bs = 0; $up = 0
foreach ($f in $core) {
  $p = Join-Path $Scripts $f
  $bs += @(Select-String -Path $p -Pattern "(Join-Path|Test-Path|-LiteralPath|Get-ChildItem|Get-Content|Set-Content|New-Item).*(\.claude|scratch|autopro-theater)[^'`"]*\\" -AllMatches).Count
  $up += @(Select-String -Path $p -Pattern '\$env:USERPROFILE' -AllMatches | Where-Object { $_.Line -notmatch '\?\?\s*\$HOME' }).Count
}
if ($bs -eq 0) { Ok 'source: 0 functional backslash paths in core scripts' } else { Bad ("source: {0} backslash-path lines remain" -f $bs) }
if ($up -eq 0) { Ok 'source: 0 unguarded $env:USERPROFILE in core scripts' } else { Bad ("source: {0} unguarded USERPROFILE" -f $up) }

Write-Output ''
if ($fail -eq 0) { Write-Output '==== ALL PASS ====' } else { Write-Output ("==== $fail FAILED ====") ; exit 1 }