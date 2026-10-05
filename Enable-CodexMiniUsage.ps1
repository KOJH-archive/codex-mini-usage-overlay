$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$disabledPath = Join-Path $root "codex-mini-usage.disabled"
$startScript = Join-Path $root "Start-CodexMiniUsage.ps1"

if (Test-Path $disabledPath) {
  Remove-Item -LiteralPath $disabledPath -Force
}

Start-Process -FilePath powershell -ArgumentList @(
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  $startScript
) -WindowStyle Hidden

Write-Host "Codex Mini Usage is enabled."
