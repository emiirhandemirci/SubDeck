# SubDeck installer / updater. Usage: .\install.ps1 [-Tool claude|codex|copilot|cursor|antigravity|opencode] [-Uninstall] [-Hooks]
#   claude (default): talks to the claude CLI only.
#   opencode: plugin + 3 commands into $env:OPENCODE_CONFIG_HOME or ~.configopencode, plugin copy in $env:SUBDECK_PLUGIN_COPY or ~.subdeckplugin.
#   cursor / antigravity: assemble the generated plugin (+ scripts) in ~.cursorpluginsocalsubdeck / ~.subdeckntigravity-plugin (SUBDECK_ANTIGRAVITY_DIR); antigravity then runs agy plugin install when agy is present.
#   codex:   writes the agents as Codex custom-agent TOML to $env:CODEX_HOME or ~\.codex\agents
#   copilot: writes the agents as <name>.agent.md to $env:COPILOT_HOME or ~\.copilot\agents plus
#            hooks\subdeck.json pointing at this clone's scripts (-Hooks adds the hooks file, only if the plugin's own hooks do not fire).
# Written files carry a "managed by SubDeck" marker; -Uninstall removes only those and an existing
# foreign file of the same name is never overwritten. Never edits settings files.
param(
  [ValidateSet('claude', 'codex', 'copilot', 'cursor', 'antigravity', 'opencode')][string]$Tool = 'claude',
  [switch]$Uninstall,
  [switch]$Hooks
)
$Repo = 'emiirhandemirci/SubDeck'
$Mkt = 'subdeck'
$Plugin = 'subdeck@subdeck'
$Mark = 'managed by SubDeck install script'
$AgentDir = Join-Path $PSScriptRoot 'plugins\subdeck\agents'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Get-Fm([string[]]$Lines, [string]$Key) {
  $c = 0
  foreach ($l in $Lines) {
    $l = $l.TrimEnd("`r")
    if ($l -eq '---') { $c++; continue }
    if ($c -eq 1) {
      $i = $l.IndexOf(':')
      if ($i -gt 0 -and $l.Substring(0, $i) -eq $Key) { return $l.Substring($i + 1).Trim() }
    }
    if ($c -ge 2) { break }
  }
  return ''
}
function Get-Body([string[]]$Lines) {
  $c = 0; $out = @()
  foreach ($l in $Lines) {
    $l = $l.TrimEnd("`r")
    if ($c -ge 2) { $out += $l; continue }
    if ($l -eq '---') { $c++ }
  }
  return $out
}
function Esc([string]$s) { return $s.Replace('\', '\\').Replace('"', '\"') }
function Test-Owned([string]$Path) {
  if (-not (Test-Path $Path)) { return $true }
  return [bool](Select-String -Path $Path -Pattern $Mark -SimpleMatch -Quiet)
}
function Write-Lf([string]$Path, [string[]]$Lines) {
  [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $Utf8)
  Write-Host "wrote $Path"
}

if ($Tool -eq 'cursor' -or $Tool -eq 'antigravity') {
  $pl = Join-Path $PSScriptRoot 'plugins\subdeck'
  if ($Tool -eq 'cursor') {
    $cb = if ($env:CURSOR_HOME) { $env:CURSOR_HOME } else { Join-Path $HOME '.cursor' }
    $dest = Join-Path $cb 'plugins\local\subdeck'; $chk = Join-Path $PSScriptRoot '.cursor-plugin\plugin.json'
  } else {
    $dest = if ($env:SUBDECK_ANTIGRAVITY_DIR) { $env:SUBDECK_ANTIGRAVITY_DIR } else { Join-Path $HOME '.subdeck\antigravity-plugin' }
    $chk = Join-Path $pl '.antigravity\plugin.json'
  }
  $marker = Join-Path $dest '.subdeck-managed'
  if ($Uninstall) {
    if (Test-Path $marker) { Remove-Item $dest -Recurse -Force; Write-Host "removed $dest" } else { Write-Host "nothing to remove at $dest" }
    if ($Tool -eq 'antigravity') { Write-Host 'Also run: agy plugin uninstall subdeck' }
    exit 0
  }
  if (-not (Test-Path $chk)) { Write-Host "missing $chk (run from a SubDeck clone; plugins/subdeck/scripts/build-portable.sh regenerates it)"; exit 1 }
  if ((Test-Path $dest) -and -not (Test-Path $marker)) { Write-Host "skip $dest (exists and is not managed by SubDeck)"; exit 0 }
  if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  if ($Tool -eq 'cursor') {
    Copy-Item (Join-Path $PSScriptRoot '.cursor-plugin') (Join-Path $dest '.cursor-plugin') -Recurse -Force
    $sub = Join-Path $dest 'plugins\subdeck'; New-Item -ItemType Directory -Force -Path $sub | Out-Null
    Copy-Item (Join-Path $pl 'skills-portable') (Join-Path $sub 'skills-portable') -Recurse -Force
    Copy-Item (Join-Path $pl 'scripts') (Join-Path $sub 'scripts') -Recurse -Force
  } else {
    Copy-Item (Join-Path $pl '.antigravity\*') $dest -Recurse -Force
    Copy-Item (Join-Path $pl 'scripts') (Join-Path $dest 'scripts') -Recurse -Force
  }
  [IO.File]::WriteAllText($marker, "$Mark`n", $Utf8)
  Write-Host "wrote $dest"
  Write-Host ''
  if ($Tool -eq 'cursor') {
    Write-Host "Restart Cursor or run 'Developer: Reload Window'; SubDeck appears under Customize. Skills, sub-agents and the rulebook rule are loaded; guard and logging hooks are not shipped for Cursor."
  } else {
    $agy = Get-Command agy -ErrorAction SilentlyContinue
    if ($agy) {
      & $agy.Source plugin install $dest
      if ($LASTEXITCODE -ne 0) { Write-Host "agy plugin install failed; run it yourself: agy plugin install `"$dest`"" }
    } else { Write-Host "Antigravity CLI (agy) not found. Install the plugin with: agy plugin install `"$dest`"" }
    Write-Host "Guard and logging hooks are not shipped for Antigravity. Gemini CLI users: gemini extensions install https://github.com/$Repo"
  }
  exit 0
}

if ($Tool -eq 'opencode') {
  $pl = Join-Path $PSScriptRoot 'plugins\subdeck'
  $oc = if ($env:OPENCODE_CONFIG_HOME) { $env:OPENCODE_CONFIG_HOME } else { Join-Path $HOME '.config\opencode' }
  $copy = if ($env:SUBDECK_PLUGIN_COPY) { $env:SUBDECK_PLUGIN_COPY } else { Join-Path $HOME '.subdeck\plugin' }
  $marker = Join-Path $copy '.subdeck-managed'
  $cmdNames = 'subdeck-status.md', 'subdeck-settings.md', 'subdeck-desk.md'
  if ($Uninstall) {
    if (Test-Path $marker) {
      Remove-Item (Join-Path $oc 'plugins\subdeck.js') -Force -ErrorAction SilentlyContinue
      foreach ($c in $cmdNames) { Remove-Item (Join-Path $oc "commands\$c") -Force -ErrorAction SilentlyContinue }
      Remove-Item $copy -Recurse -Force
      Write-Host "removed OpenCode plugin, commands and $copy"
    } else { Write-Host "nothing to remove (no SubDeck copy at $copy)" }
    Write-Host 'If you added SubDeck to the "instructions" array in opencode.json, remove that entry yourself.'
    exit 0
  }
  if (-not (Test-Path (Join-Path $pl 'opencode\subdeck.js'))) { Write-Host "missing $pl\opencode\subdeck.js (run from a SubDeck clone)"; exit 1 }
  if ((Test-Path $copy) -and -not (Test-Path $marker)) { Write-Host "skip $copy (exists and is not managed by SubDeck)"; exit 0 }
  if (-not (Test-Path $marker) -and ((Test-Path (Join-Path $oc 'plugins\subdeck.js')) -or (Test-Path (Join-Path $oc 'commands\subdeck-status.md')))) { Write-Host "skip: $oc already has a subdeck plugin or command that SubDeck did not write"; exit 0 }
  New-Item -ItemType Directory -Force -Path (Join-Path $oc 'plugins'), (Join-Path $oc 'commands'), (Split-Path $copy -Parent) | Out-Null
  if (Test-Path $copy) { Remove-Item $copy -Recurse -Force }
  Copy-Item $pl $copy -Recurse -Force
  Remove-Item (Join-Path $copy 'tests') -Recurse -Force -ErrorAction SilentlyContinue
  [IO.File]::WriteAllText($marker, "$Mark`n", $Utf8)
  Copy-Item (Join-Path $pl 'opencode\subdeck.js') (Join-Path $oc 'plugins\subdeck.js') -Force
  Copy-Item (Join-Path $pl 'opencode\commands\*.md') (Join-Path $oc 'commands') -Force
  Write-Host "wrote $oc\plugins\subdeck.js, three commands in $oc\commands, and $copy"
  Write-Host ''
  Write-Host "Rulebook: add this to $oc\opencode.json yourself (the installer never edits settings files):"
  Write-Host "  {`"instructions`": [`"$($copy.Replace('\', '/'))/skills/orchestrator/SKILL.md`"]}"
  Write-Host 'Needs bash (Git Bash on Windows). Restart OpenCode. Commands: /subdeck-status, /subdeck-settings, /subdeck-desk.'
  exit 0
}

if ($Tool -ne 'claude') {
  if ($Tool -eq 'codex') {
    $base = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $ext = 'toml'
  } else {
    $base = if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $HOME '.copilot' }
    $ext = 'agent.md'
  }
  $adir = Join-Path $base 'agents'
  $names = @(Get-ChildItem -Path $AgentDir -Filter '*.md' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
  if ($Uninstall) {
    $n = 0
    foreach ($a in $names) {
      $f = Join-Path $adir "$a.$ext"
      if ((Test-Path $f) -and (Select-String -Path $f -Pattern $Mark -SimpleMatch -Quiet)) { Remove-Item $f -Force; Write-Host "removed $f"; $n++ }
    }
    $hf = Join-Path $base 'hooks\subdeck.json'
    if ($Tool -eq 'copilot' -and (Test-Path $hf) -and (Select-String -Path $hf -Pattern 'SUBDECK_TOOL' -SimpleMatch -Quiet)) { Remove-Item $hf -Force; Write-Host "removed $hf"; $n++ }
    Write-Host "SubDeck $Tool files removed: $n."
    exit 0
  }
  if ($names.Count -eq 0) { Write-Host "Agent sources not found at $AgentDir (run from a SubDeck clone)."; exit 1 }
  New-Item -ItemType Directory -Force -Path $adir | Out-Null
  foreach ($a in $names) {
    $lines = [IO.File]::ReadAllLines((Join-Path $AgentDir "$a.md"))
    $desc = Get-Fm $lines 'description'; $model = Get-Fm $lines 'model'; $effort = Get-Fm $lines 'effort'; $tools = Get-Fm $lines 'tools'
    $readOnly = ($tools -ne '') -and ($tools -notmatch 'Bash|Write|Edit')
    $out = Join-Path $adir "$a.$ext"
    if (-not (Test-Owned $out)) { Write-Host "skip $out (not managed by SubDeck)"; continue }
    if ($Tool -eq 'copilot') {
      $gen = Join-Path $PSScriptRoot "plugins/subdeck/.github/agents/$a.agent.md"
      if (-not (Test-Path $gen)) { Write-Host "missing $gen (run plugins/subdeck/scripts/build-portable.sh)"; exit 1 }
      Copy-Item $gen $out -Force; Write-Host "wrote $out"; continue
    }
    $body = Get-Body $lines
    if ($Tool -eq 'codex') {
      if ($model -eq 'opus') { $effort = 'high' }
      $o = @("# $Mark; do not edit (re-run install.ps1 -Tool codex to refresh)", "name = `"$a`"", "description = `"$(Esc $desc)`"")
      if ($effort -in 'low', 'medium', 'high') { $o += "model_reasoning_effort = `"$effort`"" }
      if ($readOnly) { $o += 'sandbox_mode = "read-only"' }
      $o += "developer_instructions = '''"; $o += $body; $o += "'''"
    } else {
      $o = @('---', "name: $a", "description: `"$(Esc $desc)`"")
      if ($readOnly) { $o += 'tools: ["read", "search"]' }
      $o += '---'; $o += "<!-- $Mark -->"; $o += $body
    }
    Write-Lf $out $o
  }
  if ($Tool -eq 'copilot' -and $Hooks) {
    $root = (Join-Path $PSScriptRoot 'plugins\subdeck').Replace('\', '/')
    $hdir = Join-Path $base 'hooks'
    New-Item -ItemType Directory -Force -Path $hdir | Out-Null
    $hf = Join-Path $hdir 'subdeck.json'
    if ((Test-Path $hf) -and -not (Select-String -Path $hf -Pattern 'SUBDECK_TOOL' -SimpleMatch -Quiet)) {
      Write-Host "skip $hf (not managed by SubDeck)"
    } else {
      $tpl = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'plugins\subdeck\hooks\copilot-hooks.json'))
      [IO.File]::WriteAllText($hf, $tpl.Replace('__ROOT__', $root), $Utf8)
      Write-Host "wrote $hf"
    }
  }
  Write-Host ''
  if ($Tool -eq 'codex') {
    Write-Host "Now install the plugin (skills + hooks): codex plugin marketplace add $Repo; codex plugin add $Plugin"
    Write-Host 'Codex asks you to review and trust the hooks on first use. Restart Codex afterwards.'
  } else {
    Write-Host "Now install the plugin (skills, hooks, agents): copilot plugin marketplace add $Repo; copilot plugin install $Plugin"
    Write-Host "Hooks come from the plugin; add -Hooks only if they do not fire (that file runs this clone's scripts, so keep the clone). Restart Copilot afterwards."
  }
  exit 0
}

$claude = $null
$cmd = Get-Command claude -ErrorAction SilentlyContinue
if ($cmd) { $claude = $cmd.Source }
if (-not $claude) {
  foreach ($c in @((Join-Path $HOME '.local\bin\claude.exe'), (Join-Path $HOME '.local\bin\claude'))) {
    if (Test-Path $c) { $claude = $c; break }
  }
}
if (-not $claude) {
  Write-Host 'Claude Code CLI not found.'
  Write-Host 'Install Claude Code first: https://docs.claude.com/en/docs/claude-code/setup'
  exit 1
}

function Run-Claude {
  & $claude @args
  if ($LASTEXITCODE -ne 0) { exit 1 }
}

if ($Uninstall) {
  Run-Claude plugin uninstall $Plugin
  Run-Claude plugin marketplace remove $Mkt
  Write-Host 'SubDeck uninstalled. Restart Claude Code.'
  exit 0
}

$list = (& $claude plugin marketplace list 2>$null | Out-String)
if ($list -match "(?m)\b$Mkt\b") {
  Write-Host 'SubDeck marketplace found; updating.'
  Run-Claude plugin marketplace update $Mkt
  Run-Claude plugin update $Plugin
} else {
  Run-Claude plugin marketplace add $Repo
  Run-Claude plugin install $Plugin
}

Write-Host ''
(& $claude plugin list 2>$null | Out-String) -split "`n" | Select-String -Pattern 'subdeck' -Context 0,3 | Select-Object -First 1 | ForEach-Object { $_.Line; $_.Context.PostContext }
Write-Host ''
Write-Host 'Restart Claude Code to load the plugin (in a running session, /reload-plugins also works; until then subdeck agent types may be reported missing).'
Write-Host 'Then try /subdeck:status, or start the dashboard with /subdeck:desk.'
