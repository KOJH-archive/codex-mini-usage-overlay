$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $root "Start-CodexMiniUsage.ps1"
$disabledPath = Join-Path $root "codex-mini-usage.disabled"
$startup = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startup "Codex Mini Usage.lnk"

if (Test-Path $disabledPath) {
  Remove-Item -LiteralPath $disabledPath -Force
}

$existing = Get-CimInstance Win32_Process | Where-Object {
  $_.CommandLine -like "*Start-CodexMiniUsage.ps1*" -or
  $_.CommandLine -like "*codex-mini-usage-agent.mjs*"
}
foreach ($process in $existing) {
  if ($process.ProcessId -ne $PID) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
  }
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "powershell.exe"
$shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$target`""
$shortcut.WorkingDirectory = $root
$shortcut.WindowStyle = 7
$shortcut.Description = "Show Codex usage when Codex MINI is visible"
$shortcut.Save()

Start-Process -FilePath powershell -ArgumentList @(
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-File",
  $target
) -WindowStyle Hidden

Write-Host "Installed Codex Mini Usage startup shortcut:"
Write-Host $shortcutPath
