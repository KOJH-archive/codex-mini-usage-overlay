param(
  [int]$RefreshSeconds = 60,
  [switch]$AlwaysVisible,
  [switch]$NoAgent
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$logPath = Join-Path $root "codex-mini-usage-ui.log"
$agentPath = Join-Path $root "codex-mini-usage-agent.mjs"
$statusPath = Join-Path $root "codex-mini-usage-status.json"
$disabledPath = Join-Path $root "codex-mini-usage.disabled"

function Write-UiLog([string]$message) {
  Add-Content -Path $logPath -Encoding UTF8 -Value "$(Get-Date -Format o) $message"
}

if ((Test-Path $disabledPath) -and -not $AlwaysVisible) {
  Write-UiLog "Disabled marker exists; exiting."
  return
}

$mutex = New-Object System.Threading.Mutex($false, "Global\CodexMiniUsageDisplay")
if (-not $mutex.WaitOne(0, $false)) {
  Write-UiLog "Another display instance is already running; exiting."
  return
}

Write-UiLog "Starting display. AlwaysVisible=$AlwaysVisible NoAgent=$NoAgent"

$node = (Get-Command node -ErrorAction Stop).Source
$agentProcess = $null

if (-not $NoAgent) {
  $agentArgs = @(
    $agentPath,
    "--out", $statusPath,
    "--intervalMs", ([Math]::Max(15000, $RefreshSeconds * 1000)).ToString()
  )

  $agentProcess = Start-Process `
    -FilePath $node `
    -ArgumentList $agentArgs `
    -WindowStyle Hidden `
    -PassThru
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class CodexMiniUsageWin32 {
  public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

  [DllImport("user32.dll")]
  public static extern bool IsWindowVisible(IntPtr hWnd);

  [DllImport("user32.dll", SetLastError = true)]
  public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

  [DllImport("user32.dll", SetLastError = true)]
  public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
  }
}
"@

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "Codex usage"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.Width = 332
$form.Height = 36
$form.BackColor = [System.Drawing.Color]::FromArgb(28, 31, 36)
$form.Opacity = 0.96

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Left = $screen.Right - $form.Width - 18
$form.Top = $screen.Bottom - $form.Height - 18

$font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)
$detailFont = New-Object System.Drawing.Font("Segoe UI", 8.25, [System.Drawing.FontStyle]::Regular)

$label = New-Object System.Windows.Forms.Label
$label.Left = 12
$label.Top = 8
$label.Width = $form.Width - 62
$label.Height = 18
$label.Font = $font
$label.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 243)
$label.Text = "5h --% (--) · W --% (--)"
$label.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($label)

$offButton = New-Object System.Windows.Forms.Button
$offButton.Left = $form.Width - 46
$offButton.Top = 6
$offButton.Width = 34
$offButton.Height = 24
$offButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$offButton.FlatAppearance.BorderSize = 0
$offButton.Font = New-Object System.Drawing.Font("Segoe UI", 8.25, [System.Drawing.FontStyle]::Regular)
$offButton.Text = "off"
$offButton.ForeColor = [System.Drawing.Color]::FromArgb(190, 198, 210)
$offButton.BackColor = [System.Drawing.Color]::FromArgb(42, 46, 53)
$offButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($offButton)

$detail = New-Object System.Windows.Forms.Label
$detail.Left = 12
$detail.Top = 34
$detail.Width = $form.Width - 24
$detail.Height = 52
$detail.Font = $detailFont
$detail.ForeColor = [System.Drawing.Color]::FromArgb(190, 198, 210)
$detail.Text = "Waiting for Codex usage..."
$detail.Visible = $false
$form.Controls.Add($detail)

$expanded = $false
$dragging = $false
$dragOffset = New-Object System.Drawing.Point

function Set-Expanded([bool]$value) {
  $script:expanded = $value
  $detail.Visible = $value
  $form.Height = $(if ($value) { 92 } else { 36 })
}

function Set-Theme([string]$severity, [bool]$ok) {
  if (-not $ok) {
    $form.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $label.ForeColor = [System.Drawing.Color]::FromArgb(210, 214, 222)
    $offButton.BackColor = [System.Drawing.Color]::FromArgb(58, 58, 62)
    return
  }

  switch ($severity) {
    "critical" {
      $form.BackColor = [System.Drawing.Color]::FromArgb(82, 32, 38)
      $label.ForeColor = [System.Drawing.Color]::FromArgb(255, 220, 224)
      $offButton.BackColor = [System.Drawing.Color]::FromArgb(104, 44, 52)
    }
    "warning" {
      $form.BackColor = [System.Drawing.Color]::FromArgb(76, 57, 28)
      $label.ForeColor = [System.Drawing.Color]::FromArgb(255, 236, 204)
      $offButton.BackColor = [System.Drawing.Color]::FromArgb(97, 73, 38)
    }
    default {
      $form.BackColor = [System.Drawing.Color]::FromArgb(28, 31, 36)
      $label.ForeColor = [System.Drawing.Color]::FromArgb(235, 238, 243)
      $offButton.BackColor = [System.Drawing.Color]::FromArgb(42, 46, 53)
    }
  }
}

function Clamp-Number([int]$value, [int]$min, [int]$max) {
  if ($value -lt $min) { return $min }
  if ($value -gt $max) { return $max }
  return $value
}

function Get-CodexMiniWindow {
  $candidates = New-Object System.Collections.Generic.List[object]

  [CodexMiniUsageWin32]::EnumWindows({
    param([IntPtr]$hWnd, [IntPtr]$lParam)
    if (-not [CodexMiniUsageWin32]::IsWindowVisible($hWnd)) { return $true }

    $titleBuilder = New-Object System.Text.StringBuilder 512
    $classBuilder = New-Object System.Text.StringBuilder 256
    [void][CodexMiniUsageWin32]::GetWindowText($hWnd, $titleBuilder, $titleBuilder.Capacity)
    [void][CodexMiniUsageWin32]::GetClassName($hWnd, $classBuilder, $classBuilder.Capacity)

    $title = $titleBuilder.ToString()
    $className = $classBuilder.ToString()
    if ($title -notmatch "ChatGPT|Codex" -or $className -ne "Chrome_WidgetWin_1") { return $true }

    $rect = New-Object CodexMiniUsageWin32+RECT
    [void][CodexMiniUsageWin32]::GetWindowRect($hWnd, [ref]$rect)
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top

    if ($width -ge 280 -and $width -le 1500 -and $height -ge 180 -and $height -le 1100) {
      $candidates.Add([pscustomobject]@{
        Left = $rect.Left
        Top = $rect.Top
        Right = $rect.Right
        Bottom = $rect.Bottom
        Width = $width
        Height = $height
        Area = $width * $height
      })
    }

    return $true
  }, [IntPtr]::Zero) | Out-Null

  $candidates | Sort-Object Area | Select-Object -First 1
}

function Update-Attachment {
  if ($AlwaysVisible) {
    if (-not $form.Visible) { $form.Show() }
    return
  }

  $mini = Get-CodexMiniWindow
  if (-not $mini) {
    if ($form.Visible) { Write-UiLog "No MINI candidate; hiding display." }
    if ($form.Visible) { $form.Hide() }
    return
  }

  $left = Clamp-Number `
    -value ($mini.Right - $form.Width - 14) `
    -min ($screen.Left + 8) `
    -max ($screen.Right - $form.Width - 8)
  $top = Clamp-Number `
    -value ($mini.Bottom - $form.Height - 14) `
    -min ($screen.Top + 8) `
    -max ($screen.Bottom - $form.Height - 8)

  if ($form.Left -ne $left) { $form.Left = $left }
  if ($form.Top -ne $top) { $form.Top = $top }
  if (-not $form.Visible) {
    Write-UiLog ("Showing display for MINI candidate {0}x{1} at {2},{3}; display at {4},{5}." -f $mini.Width, $mini.Height, $mini.Left, $mini.Top, $left, $top)
    $form.Show()
  }
}

function Update-Usage {
  try {
    if (-not (Test-Path $statusPath)) {
      $label.Text = "Codex usage starting..."
      $detail.Text = "Waiting for first reading."
      Set-Theme "unknown" $false
      return
    }

    $status = Get-Content $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $label.Text = $status.display

    if ($status.ok) {
      $updated = ([datetime]$status.updatedAt).ToLocalTime().ToString("HH:mm:ss")
      $detail.Text = "5h left $($status.fiveHour.remainingPercent)% · reset $($status.fiveHour.resetIn)`r`nW left $($status.weekly.remainingPercent)% · reset $($status.weekly.resetIn)`r`nUpdated $updated"
    } elseif ($status.lastGood) {
      $detail.Text = "Using last reading. Latest refresh failed.`r`n$($status.error)"
    } else {
      $detail.Text = "Could not read Codex usage yet.`r`n$($status.error)"
    }

    Set-Theme $status.severity $status.ok
  } catch {
    $label.Text = "Usage unavailable"
    $detail.Text = $_.Exception.Message
    Set-Theme "unknown" $false
  }
}

$toggle = {
  if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left -and -not $script:dragging) {
    Set-Expanded (-not $script:expanded)
  }
}

$mouseDown = {
  if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    $script:dragging = $false
    $script:dragOffset = New-Object System.Drawing.Point($_.X, $_.Y)
  }
}

$mouseMove = {
  if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    $point = [System.Windows.Forms.Control]::MousePosition
    $newLeft = $point.X - $script:dragOffset.X
    $newTop = $point.Y - $script:dragOffset.Y
    if ([Math]::Abs($form.Left - $newLeft) -gt 2 -or [Math]::Abs($form.Top - $newTop) -gt 2) {
      $script:dragging = $true
      $form.Left = $newLeft
      $form.Top = $newTop
    }
  }
}

$rightClick = {
  if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
    $form.Close()
  }
}

foreach ($control in @($form, $label, $detail)) {
  $control.Add_MouseDown($mouseDown)
  $control.Add_MouseMove($mouseMove)
  $control.Add_MouseUp($toggle)
  $control.Add_MouseClick($rightClick)
}

$offButton.Add_Click({
  Set-Content -Path $disabledPath -Value "disabled" -Encoding UTF8
  $form.Close()
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({
  Update-Attachment
  Update-Usage
})
$timer.Start()

$form.Add_Shown({
  Update-Attachment
  Update-Usage
})
$form.Add_FormClosed({
  $timer.Stop()
  if ($agentProcess -and -not $agentProcess.HasExited) {
    Stop-Process -Id $agentProcess.Id -Force
  }
  if ($mutex) {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
  }
})

[System.Windows.Forms.Application]::Run($form)
