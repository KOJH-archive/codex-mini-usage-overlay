$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$startup = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startup "Codex Mini Usage.lnk"
$disabledPath = Join-Path $root "codex-mini-usage.disabled"

$existing = Get-CimInstance Win32_Process | Where-Object {
  $_.CommandLine -like "*Start-CodexMiniUsage.ps1*" -or
  $_.CommandLine -like "*codex-mini-usage-agent.mjs*"
}

foreach ($process in $existing) {
  if ($process.ProcessId -ne $PID) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
  }
}

if (Test-Path $shortcutPath) {
  Remove-Item -LiteralPath $shortcutPath -Force
}

if (Test-Path $disabledPath) {
  Remove-Item -LiteralPath $disabledPath -Force
}

Write-Host "Codex Mini Usage startup entry was removed."
