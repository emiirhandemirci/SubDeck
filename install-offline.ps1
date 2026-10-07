# SubDeck offline installer (Windows PowerShell 5.1). Run from the unzipped bundle folder. No network access.
# Usage: .\install-offline.ps1 [-Target <dir>] [-ModeCurrent] [-Uninstall]
#   -Target <dir>   permanent copy of the plugin (default %USERPROFILE%\.subdeck\offline\SubDeck)
#   -ModeCurrent    write mode=current so sub-agents use the session's model (non-Claude backends such as GLM)
#   -Uninstall      remove the plugin, the marketplace entry and our copy
# Replaces only an older copy of ours (marker file .subdeck-offline-install); never touches other files.
param(
  [string]$Target = (Join-Path $HOME '.subdeck\offline\SubDeck'),
  [switch]$ModeCurrent,
  [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$Mkt = 'subdeck'
$Plugin = 'subdeck@subdeck'
$Marker = '.subdeck-offline-install'
$Here = $PSScriptRoot
if (-not [IO.Path]::IsPathRooted($Target)) { $Target = Join-Path (Get-Location).Path $Target }
$Target = [IO.Path]::GetFullPath($Target)

function Fail([string]$m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# --- claude CLI ---
$claude = $null
$cmd = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cmd) { $claude = $cmd.Source }
if (-not $claude) {
  foreach ($c in @((Join-Path $HOME '.local\bin\claude.exe'), (Join-Path $HOME '.local\bin\claude.cmd'), (Join-Path $HOME '.local\bin\claude'))) {
    if (Test-Path $c) { $claude = $c; break }
  }
}
if (-not $claude) { Fail "the 'claude' command was not found. Install Claude Code first, or add its folder (for example %USERPROFILE%\.local\bin) to PATH." }
Write-Host "Claude Code: $claude"

if ($Uninstall) {
  & $claude plugin uninstall $Plugin
  if ($LASTEXITCODE -ne 0) { Write-Host 'note: plugin was not installed (or could not be removed)' }
  & $claude plugin marketplace remove $Mkt
  if ($LASTEXITCODE -ne 0) { Write-Host 'note: marketplace entry was not present' }
  if (Test-Path (Join-Path $Target $Marker)) { Remove-Item -Recurse -Force $Target; Write-Host "Removed $Target" }
  elseif (Test-Path $Target) { Write-Host "Left $Target alone (not an offline copy written by SubDeck)" }
  Write-Host 'SubDeck removed. Restart Claude Code.'
  exit 0
}

# --- Git Bash (the plugin hooks are bash scripts) ---
$bash = $null
$git = Get-Command git -ErrorAction SilentlyContinue | Select-Object -First 1
$cands = @()
if ($git) {
  $gdir = Split-Path (Split-Path $git.Source)
  $cands += (Join-Path $gdir 'bin\bash.exe')
  $cands += (Join-Path $gdir 'usr\bin\bash.exe')
}
$cands += 'C:\Program Files\Git\bin\bash.exe'
$cands += 'C:\Program Files (x86)\Git\bin\bash.exe'
if ($env:LOCALAPPDATA) { $cands += (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe') }
foreach ($c in $cands) { if (Test-Path $c) { $bash = $c; break } }
if (-not $bash) { Fail 'Git Bash was not found. Install Git for Windows (https://git-scm.com/download/win); the plugin hooks need bash.' }
Write-Host "Git Bash: $bash"

# --- Node (Desk only: warn, do not fail) ---
$node = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
if ($node) {
  $nv = (& $node.Source -v).TrimStart('v')
  try { $ok = ([version]($nv -replace '[^0-9.].*$', '')) -ge [version]'22.13' } catch { $ok = $false }
  if (-not $ok) { Write-Host "WARNING: Node.js $nv found, Desk needs 22.13 or newer. The plugin works without Desk." -ForegroundColor Yellow }
} else {
  Write-Host 'WARNING: Node.js not found. Desk (the live web view) needs Node.js 22.13 or newer; the plugin works without it.' -ForegroundColor Yellow
}

# --- copy to the permanent place ---
if (-not ((Test-Path (Join-Path $Here 'plugins\subdeck\.claude-plugin\plugin.json')) -and (Test-Path (Join-Path $Here '.claude-plugin\marketplace.json')))) {
  Fail 'run this from the unzipped SubDeck bundle folder (plugins\subdeck not found next to the script).'
}
$same = ([IO.Path]::GetFullPath($Here).TrimEnd('\') -ieq $Target.TrimEnd('\'))
if (-not $same) {
  if ((Test-Path $Target) -and (Get-ChildItem -Force $Target | Select-Object -First 1) -and -not (Test-Path (Join-Path $Target $Marker))) {
    Fail "$Target exists and is not a SubDeck offline copy; refusing to overwrite. Use -Target <other folder>."
  }
  if (Test-Path $Target) { Remove-Item -Recurse -Force $Target }
  New-Item -ItemType Directory -Force $Target | Out-Null
  Get-ChildItem -Force $Here | Copy-Item -Destination $Target -Recurse -Force
}
$verLine = Select-String -Path (Join-Path $Target 'plugins\subdeck\.claude-plugin\plugin.json') -Pattern '"version"\s*:\s*"([^"]*)"' | Select-Object -First 1
$ver = if ($verLine) { $verLine.Matches[0].Groups[1].Value } else { '' }
[IO.File]::WriteAllText((Join-Path $Target $Marker), "SubDeck offline copy, version $ver. Written by install-offline; safe to replace or delete.`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Copied SubDeck $ver to $Target"

# --- marketplace + plugin (local directory: Claude Code reads it in place, no network) ---
function Norm([string]$s) { return ($s -replace '\\', '/').ToLowerInvariant() }
$mlist = @(& $claude plugin marketplace list)
$listed = $false; $srcLine = ''
for ($i = 0; $i -lt $mlist.Count; $i++) {
  if (($mlist[$i].Trim() -split '\s+')[-1] -eq $Mkt) {
    $listed = $true
    for ($j = $i + 1; $j -lt $mlist.Count; $j++) { if ($mlist[$j] -match 'Source:') { $srcLine = $mlist[$j]; break } }
    break
  }
}
if ($listed -and (Norm $srcLine).Contains((Norm $Target))) {
  & $claude plugin marketplace update $Mkt
  if ($LASTEXITCODE -ne 0) { Fail 'marketplace update failed' }
} else {
  if ($listed) {
    Write-Host "Replacing the existing '$Mkt' marketplace entry with the local copy"
    & $claude plugin marketplace remove $Mkt
    if ($LASTEXITCODE -ne 0) { Fail 'could not remove the old marketplace entry' }
  }
  & $claude plugin marketplace add $Target
  if ($LASTEXITCODE -ne 0) { Fail 'marketplace add failed' }
}
$plist = (@(& $claude plugin list) -join "`n")
if ($plist.Contains($Plugin)) {
  & $claude plugin update $Plugin
  if ($LASTEXITCODE -ne 0) { Fail 'plugin update failed' }
} else {
  & $claude plugin install $Plugin
  if ($LASTEXITCODE -ne 0) { Fail 'plugin install failed' }
}

# --- model mode ---
$models = (Join-Path $Target 'plugins\subdeck\scripts\models.sh') -replace '\\', '/'
if ($ModeCurrent) {
  & $bash $models set mode=current
} elseif ($env:ANTHROPIC_BASE_URL -and $env:ANTHROPIC_BASE_URL -notmatch '^https?://([^/]*\.)?(anthropic\.com|claude\.com)(/|:|$)') {
  Write-Host 'NOTE: ANTHROPIC_BASE_URL points to a non-Anthropic backend. Recommended: re-run with -ModeCurrent' -ForegroundColor Yellow
  Write-Host '      (or run /subdeck:settings set mode=current) so sub-agents use your session''s model.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host "SubDeck $ver installed from $Target (no network used)."
Write-Host 'Next steps:'
Write-Host '  1. Restart Claude Code (or run /reload-plugins in a running session).'
Write-Host '  2. Run /subdeck:status to check the plugin, and /subdeck:desk for the live web view (needs Node.js 22.13+).'
Write-Host '  3. Smoke test in a throwaway folder: ask "Use a worker to create hello.txt containing hello, then verify it."'
Write-Host 'Update: unzip a newer bundle and run this installer again. Remove: .\install-offline.ps1 -Uninstall'
exit 0
