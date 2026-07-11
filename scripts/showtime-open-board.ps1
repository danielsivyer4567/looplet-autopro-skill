<#
  showtime-open-board.ps1 — open Show Time in Looplet extension if present, else browser tab.

  Always:
    - Write handoff file (showtime-open.json) for the extension
    - Open $BoardUrl in a real browser tab (Start-Process → cmd start → Chrome/Edge)

  Additive (never suppress the browser tab):
    - Companion POST open hook on :4321 / :4322 if present
    - chrome-extension:// deep link if Looplet extension ID is known

  Extension ID discovery:
    1. Env LOOPLET_EXTENSION_ID
    2. Config %USERPROFILE%\.claude\scratch\looplet-extension.json
    3. Scan Chrome / Edge / Brave profile Extensions for name ~ Looplet
#>
param(
  [Parameter(Mandatory = $true)][string]$BoardUrl,
  [string]$SessionId = '',
  [switch]$NoBrowser
)

$ErrorActionPreference = 'Continue'
$scratch = Join-Path $env:USERPROFILE '.claude\scratch'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$handoffPath = Join-Path $scratch 'showtime-open.json'
$configPath = Join-Path $scratch 'looplet-extension.json'

function Write-Handoff([string]$mode, [string]$url, [string]$extId = '') {
  $obj = [ordered]@{
    op         = 'showtime-open'
    mode       = $mode
    boardUrl   = $url
    sessionId  = $SessionId
    extensionId = $extId
    at         = (Get-Date).ToUniversalTime().ToString('o')
  }
  ($obj | ConvertTo-Json -Compress) | Set-Content -LiteralPath $handoffPath -Encoding utf8
  Write-Output "HANDOFF=$handoffPath"
}

function Get-ConfigExt {
  if (-not (Test-Path -LiteralPath $configPath)) { return $null }
  try {
    return Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
  } catch { return $null }
}

function Find-InstalledLoopletId {
  $roots = @(
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Extensions'),
    (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Profile 1\Extensions'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Extensions'),
    (Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data\Default\Extensions')
  )
  $hits = @()
  foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $id = $_.Name
      $manif = Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter manifest.json -Depth 2 -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
      if (-not $manif) { return }
      try {
        $j = Get-Content -LiteralPath $manif.FullName -Raw | ConvertFrom-Json
        $name = [string]$j.name
        # Chrome __MSG_appName__ — also match description
        $blob = "$name $($j.description) $($j.short_name)"
        if ($blob -match '(?i)looplet|ai sidebar|show\s*time') {
          $hits += [pscustomobject]@{
            Id   = $id
            Name = $name
            Path = $manif.FullName
          }
        }
      } catch {}
    }
  }
  # Prefer exact Looplet name
  $exact = $hits | Where-Object { $_.Name -match '(?i)^looplet$' } | Select-Object -First 1
  if ($exact) { return $exact }
  return $hits | Select-Object -First 1
}

function Test-CompanionOpen([string]$boardUrl) {
  foreach ($port in 4321, 4322) {
    $base = "http://127.0.0.1:$port"
    try {
      $h = Invoke-WebRequest -Uri "$base/healthz" -UseBasicParsing -TimeoutSec 1 -ErrorAction Stop
      if ($h.StatusCode -ge 200 -and $h.StatusCode -lt 500) {
        # Try known open endpoints (extension companion may implement one)
        foreach ($path in @('/showtime/open', '/api/showtime/open', '/board/open')) {
          try {
            $body = @{ url = $boardUrl; sessionId = $SessionId } | ConvertTo-Json -Compress
            $r = Invoke-WebRequest -Uri "$base$path" -Method POST -Body $body -ContentType 'application/json' `
              -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) {
              Write-Output "COMPANION_OPEN=$base$path"
              return $true
            }
          } catch {}
        }
        Write-Output "COMPANION_ALIVE=$base (no open endpoint — handoff file still written)"
        return $false
      }
    } catch {}
  }
  return $false
}

function Open-ExtensionBoard([string]$extId, [string]$boardUrl) {
  # Prefer side panel / board routes; extension team can add board.html later
  $candidates = @(
    "chrome-extension://$extId/sidebar/sidebar.html?view=board&showtime=$([uri]::EscapeDataString($boardUrl))",
    "chrome-extension://$extId/sidebar/sidebar.html#board?showtime=$([uri]::EscapeDataString($boardUrl))",
    "chrome-extension://$extId/newtab/newtab.html?board=$([uri]::EscapeDataString($boardUrl))",
    "chrome-extension://$extId/options/options.html?showtime=$([uri]::EscapeDataString($boardUrl))"
  )
  foreach ($u in $candidates) {
    try {
      Start-Process $u -ErrorAction Stop
      Write-Output "OPENED_EXTENSION=$u"
      return $true
    } catch {
      # try chrome.exe with the URL
      foreach ($chrome in @(
          "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
          "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
          "${env:LOCALAPPDATA}\Google\Chrome\Application\chrome.exe",
          "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
          "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe"
        )) {
        if (Test-Path $chrome) {
          try {
            Start-Process -FilePath $chrome -ArgumentList @($u) -ErrorAction Stop
            Write-Output "OPENED_EXTENSION_VIA=$chrome"
            Write-Output "OPENED_EXTENSION=$u"
            return $true
          } catch {}
        }
      }
    }
  }
  return $false
}

function Get-ChromePath {
  foreach ($c in @(
      "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
      "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
      "${env:LOCALAPPDATA}\Google\Chrome\Application\chrome.exe"
    )) {
    if (Test-Path -LiteralPath $c) { return $c }
  }
  try {
    $rk = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe' -ErrorAction Stop
    $p = $rk.'(default)'
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  } catch {}
  return $null
}

function Open-BoardInBrowser([string]$url) {
  # Hard guarantee: open the localhost board — GOOGLE CHROME first (operator call
  # 2026-07-12: never Edge unless Chrome is missing), then default assoc fallbacks.
  # Note: do not mix Write-Output with return $bool under assignment — that
  # swallows status lines. Use $script:BoardPageOpened instead.
  $script:BoardPageOpened = $false
  $chrome = Get-ChromePath
  if ($chrome) {
    try {
      Start-Process -FilePath $chrome -ArgumentList @($url) -ErrorAction Stop
      $script:BoardPageOpened = $true
      Write-Output "OPENED_PAGE_VIA=$chrome"
      Write-Output "OPENED_PAGE=$url"
      return
    } catch {
      Write-Output "OPEN_CHROME_WARN=$($_.Exception.Message)"
    }
  } else {
    Write-Output 'OPEN_CHROME_WARN=chrome.exe not found — falling back to default browser'
  }
  try {
    Start-Process $url -ErrorAction Stop
    $script:BoardPageOpened = $true
    Write-Output "OPENED_PAGE=$url"
    return
  } catch {
    Write-Output "OPEN_PAGE_WARN=$($_.Exception.Message)"
  }
  # cmd start is more reliable when Start-Process association is broken
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = "/c start `"`" `"$url`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [void][System.Diagnostics.Process]::Start($psi)
    $script:BoardPageOpened = $true
    Write-Output "OPENED_PAGE_VIA=cmd start"
    Write-Output "OPENED_PAGE=$url"
    return
  } catch {
    Write-Output "OPEN_PAGE_CMD_WARN=$($_.Exception.Message)"
  }
  # Prefer Chrome/Edge directly if shell association still failed
  foreach ($browser in @(
      "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe",
      "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
      "${env:LOCALAPPDATA}\Google\Chrome\Application\chrome.exe",
      "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe",
      "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    )) {
    if (-not (Test-Path -LiteralPath $browser)) { continue }
    try {
      Start-Process -FilePath $browser -ArgumentList @($url) -ErrorAction Stop
      $script:BoardPageOpened = $true
      Write-Output "OPENED_PAGE_VIA=$browser"
      Write-Output "OPENED_PAGE=$url"
      return
    } catch {}
  }
  Write-Output "OPEN_PAGE_FAILED=could not open $url"
}

# --- main ---
if ($NoBrowser) {
  Write-Handoff 'none' $BoardUrl
  Write-Output 'OPEN_MODE=none'
  exit 0
}

$extId = $env:LOOPLET_EXTENSION_ID
$boardPath = 'sidebar/sidebar.html'
$cfg = Get-ConfigExt
if ($cfg) {
  if ($cfg.extensionId) { $extId = [string]$cfg.extensionId }
  if ($cfg.boardPath) { $boardPath = [string]$cfg.boardPath }
}

if (-not $extId) {
  $hit = Find-InstalledLoopletId
  if ($hit) {
    $extId = $hit.Id
    Write-Output "FOUND_EXTENSION_ID=$extId name=$($hit.Name)"
  } else {
    Write-Output 'FOUND_EXTENSION_ID='
  }
}

# Always write handoff so extension SW can poll/watch this file later
Write-Handoff $(if ($extId) { 'extension' } else { 'page' }) $BoardUrl $extId

# 1) ALWAYS open the board page in a real browser tab (primary guarantee).
#    Prior bug: companion/extension "success" skipped this, so the TV card
#    appeared in chat while localhost never opened.
$script:BoardPageOpened = $false
Open-BoardInBrowser $BoardUrl
$pageOk = [bool]$script:BoardPageOpened

# 2) Best-effort companion open hook (extension focus) — additive only
$companionOk = $false
if (Test-CompanionOpen $BoardUrl) {
  $companionOk = $true
  Write-Output 'COMPANION_OPEN_OK=1'
} else {
  Write-Output 'COMPANION_OPEN_OK=0'
}

# 3) Best-effort chrome-extension:// deep link — additive only
$extOk = $false
if ($extId) {
  if (Open-ExtensionBoard $extId $BoardUrl) {
    $extOk = $true
    Write-Output 'EXTENSION_OPEN_OK=1'
  } else {
    Write-Output 'EXTENSION_OPEN_OK=0'
    Write-Output 'HINT=Extension ID found but OS could not open chrome-extension:// — browser tab is the fallback; Looplet may still read showtime-open.json'
  }
}

if ($pageOk) {
  Write-Output 'OPEN_MODE=page'
} elseif ($companionOk) {
  Write-Output 'OPEN_MODE=companion'
} elseif ($extOk) {
  Write-Output 'OPEN_MODE=extension'
} else {
  Write-Output 'OPEN_MODE=failed'
  Write-Output "ERROR=Could not open board URL $BoardUrl"
}

Write-Output "BOARD_URL=$BoardUrl"
if ($extId) { Write-Output "EXTENSION_ID=$extId" }
