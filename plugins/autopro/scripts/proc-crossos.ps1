<#
  proc-crossos.ps1 — cross-platform process enumeration + tree-kill for AutoPro.

  Why: the runner/stop scripts used Get-CimInstance Win32_Process (Windows-only) to read each
  process's ProcessId / Name / ParentProcessId / CommandLine, and taskkill.exe /T /F to kill a
  process tree. Neither exists on macOS/Linux, so AutoPro was Windows-only. This module gives both
  operations one entry point that branches on $IsWindows:

    • Windows  → the EXACT same Get-CimInstance / taskkill calls as before (behaviour unchanged).
    • Unix     → a `ps` snapshot parsed into the same object shape, and a descendant-walk tree kill
                 via Stop-Process (pwsh 7's Stop-Process is cross-platform for a single PID).

  Requires PowerShell 7+ (pwsh) — $IsWindows is an automatic there. AutoPro already mandates pwsh.

  Dot-source it:  . (Join-Path $PSScriptRoot 'proc-crossos.ps1')
#>

# On pwsh 7, $IsWindows is $true/$false. On Windows PowerShell 5.1 it's undefined → treat as Windows.
$script:AutoproOnWindows = if ($null -eq $IsWindows) { $true } else { [bool]$IsWindows }

<#
  Return every process (optionally filtered to a set of executable base-names) as objects with a
  stable shape: ProcessId, Name, ParentProcessId, CommandLine. Same fields the CIM path exposed,
  so callers that read those properties don't change.
    -Names @('pwsh','powershell')   # base names, no .exe — matched case-insensitively both OSes
#>
function Get-AutoproProcessList {
  param([string[]]$Names)

  if ($script:AutoproOnWindows) {
    # --- Windows: unchanged CIM path (kept name-filtered — an unfiltered enum hangs on busy boxes) ---
    $cim = $null
    if ($Names -and $Names.Count) {
      $filter = (($Names | ForEach-Object { "Name='$_.exe'" }) -join ' OR ')
      $cim = Get-CimInstance Win32_Process -Filter $filter -OperationTimeoutSec 8 -ErrorAction SilentlyContinue
    } else {
      $cim = Get-CimInstance Win32_Process -OperationTimeoutSec 8 -ErrorAction SilentlyContinue
    }
    return @($cim | ForEach-Object {
      [pscustomobject]@{
        ProcessId       = [int]$_.ProcessId
        Name            = [string]$_.Name
        ParentProcessId = [int]$_.ParentProcessId
        CommandLine     = [string]$_.CommandLine
      }
    })
  }

  # --- Unix (macOS/Linux): parse a ps snapshot into the same shape ---
  # pid, ppid, comm (basename), args (full command line). -axww = all procs, wide, no truncation.
  $raw = & ps -axww -o pid=,ppid=,comm=,args= 2>$null
  $list = New-Object System.Collections.Generic.List[object]
  foreach ($line in $raw) {
    if ($line -match '^\s*(\d+)\s+(\d+)\s+(\S+)\s*(.*)$') {
      $list.Add([pscustomobject]@{
        ProcessId       = [int]$Matches[1]
        ParentProcessId = [int]$Matches[2]
        Name            = Split-Path -Leaf $Matches[3]
        CommandLine     = [string]$Matches[4]
      })
    }
  }
  # NOTE: use .ToArray(), never @($list) — on pwsh 7.6+ the array-subexpression operator over a
  # List[object] throws "Argument types do not match" (works on older pwsh; only bites on Linux 7.6).
  if ($Names -and $Names.Count) {
    $wanted = $Names | ForEach-Object { $_.ToLowerInvariant() }
    return @($list.ToArray() | Where-Object {
      $n = $_.Name.ToLowerInvariant()
      [bool]($wanted | Where-Object { $n -like "*$_*" })
    })
  }
  return $list.ToArray()
}

<#
  Look up ONE process by PID (used for parent-of-worker detection). Returns the same object shape,
  or $null if the PID isn't running. Kept separate from the filtered list so a worker's parent is
  found even when the parent isn't a worker-type process.
#>
function Get-AutoproProcessById {
  param([Parameter(Mandatory)][int]$Id)
  if ($script:AutoproOnWindows) {
    $c = Get-CimInstance Win32_Process -Filter "ProcessId=$Id" -OperationTimeoutSec 3 -ErrorAction SilentlyContinue
    if (-not $c) { return $null }
    return [pscustomobject]@{
      ProcessId       = [int]$c.ProcessId
      Name            = [string]$c.Name
      ParentProcessId = [int]$c.ParentProcessId
      CommandLine     = [string]$c.CommandLine
    }
  }
  $raw = & ps -p $Id -o pid=,ppid=,comm=,args= 2>$null
  foreach ($line in $raw) {
    if ($line -match '^\s*(\d+)\s+(\d+)\s+(\S+)\s*(.*)$') {
      return [pscustomobject]@{
        ProcessId       = [int]$Matches[1]
        ParentProcessId = [int]$Matches[2]
        Name            = Split-Path -Leaf $Matches[3]
        CommandLine     = [string]$Matches[4]
      }
    }
  }
  return $null
}

<#
  Start a process DETACHED from the parent so a terminal/CI/agent shell that exits (or kills its
  Job Object) can't take the runner/board down mid-run. Returns { ReturnValue; ProcessId; How },
  where ReturnValue -eq 0 means success — the SAME success contract Win32_Process.Create used, so
  callers keep checking `$r.ReturnValue -eq 0 -and $r.ProcessId`.
    • Windows → the EXACT same Invoke-CimMethod Win32_Process Create (starts outside the Job Object).
    • Unix    → `nohup <cmd> &` under /bin/sh so SIGHUP on terminal-close can't reap it; echoes $!.
  $CommandLine is a full command line whose executable is already the per-OS path the caller resolved
  via (Get-Command pwsh/node).Source, so no exe translation is needed here.
#>
function Start-DetachedProcess {
  param(
    [Parameter(Mandatory)][string]$CommandLine,
    [string]$CurrentDirectory = ''
  )
  if ($script:AutoproOnWindows) {
    $cimArgs = @{ CommandLine = $CommandLine }
    if ($CurrentDirectory) { $cimArgs.CurrentDirectory = $CurrentDirectory }
    $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments $cimArgs
    return [pscustomobject]@{
      ReturnValue = [int]$created.ReturnValue
      ProcessId   = if ($created.ProcessId) { [int]$created.ProcessId } else { 0 }
      How         = 'Win32_Process.Create'
    }
  }

  # Unix: cd as its OWN statement (';', not '&&'), so only `nohup <cmd>` is backgrounded and `$!` is
  # the worker's pid. A `cd … && nohup … &` compound backgrounds the whole AND-list, so `$!` would be
  # a short-lived subshell that exits and orphans the worker under a different pid (verified on WSL).
  # Single-quote the dir so spaces/specials survive.
  $cd = ''
  if ($CurrentDirectory) {
    $q = $CurrentDirectory -replace "'", "'\''"
    $cd = "cd '$q' || exit 1; "
  }
  $shell = "$cd" + 'nohup ' + $CommandLine + ' >/dev/null 2>&1 & echo $!'
  $childPid = 0
  try {
    $out = & /bin/sh -c $shell 2>$null
    foreach ($line in @($out)) { if ("$line" -match '^\s*(\d+)\s*$') { $childPid = [int]$Matches[1]; break } }
  } catch {}
  return [pscustomobject]@{
    ReturnValue = if ($childPid -gt 0) { 0 } else { 1 }
    ProcessId   = $childPid
    How         = 'nohup-sh'
  }
}

<#
  Kill a process and all its descendants. Returns $true if the root is gone afterward.
    • Windows → taskkill /PID <id> /T /F (the tree flag), with Stop-Process as a fallback — unchanged.
    • Unix    → snapshot the tree, kill leaves-first via Stop-Process (no /T flag exists).
#>
function Stop-ProcessTree {
  param([Parameter(Mandatory)][int]$Id)

  if ($script:AutoproOnWindows) {
    try {
      & taskkill.exe /PID $Id /T /F 2>&1 | Out-Null
      if ($LASTEXITCODE -eq 0) { return $true }
    } catch {}
    try { Stop-Process -Id $Id -Force -ErrorAction Stop; return $true } catch { return $false }
  }

  # Unix: build the descendant set from a fresh snapshot, then kill deepest-first.
  $all = Get-AutoproProcessList
  $childrenOf = @{}
  foreach ($p in $all) {
    if (-not $childrenOf.ContainsKey($p.ParentProcessId)) { $childrenOf[$p.ParentProcessId] = @() }
    $childrenOf[$p.ParentProcessId] += $p.ProcessId
  }
  $ordered = New-Object System.Collections.Generic.List[int]
  $stack = New-Object System.Collections.Generic.Stack[int]
  $stack.Push($Id)
  while ($stack.Count -gt 0) {
    $cur = $stack.Pop()
    $ordered.Add($cur)
    if ($childrenOf.ContainsKey($cur)) { foreach ($ch in $childrenOf[$cur]) { $stack.Push($ch) } }
  }
  # Reverse = leaves before their parents, so a parent can't re-parent/respawn a child mid-kill.
  $ordered.Reverse()
  foreach ($pidToKill in ($ordered | Select-Object -Unique)) {
    try { Stop-Process -Id $pidToKill -Force -ErrorAction SilentlyContinue } catch {}
  }
  return (-not (Get-Process -Id $Id -ErrorAction SilentlyContinue))
}
