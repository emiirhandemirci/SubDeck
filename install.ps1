# SubDeck installer / updater. Usage: .\install.ps1 [-Uninstall]
# Only talks to the claude CLI; never edits settings files.
param([switch]$Uninstall)
$Repo = 'emiirhandemirci/SubDeck'
$Mkt = 'subdeck'
$Plugin = 'subdeck@subdeck'

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
Write-Host 'Restart Claude Code to load the plugin.'
Write-Host 'Then try /subdeck:status, or start the dashboard with /subdeck:desk.'
