# Launcher for the touch viewer: makes sure a second screen exists (starts ParsecVDisplay and
# adds a virtual display when needed), then opens screen-viewer.ps1 from the same folder.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, UIAutomationClient, UIAutomationTypes

function Test-Second { @([Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary }).Count -gt 0 }
function Fail($msg) { [void][Windows.Forms.MessageBox]::Show($msg, 'Second screen viewer', 'OK', 'Error'); exit 1 }

# --- locate files -----------------------------------------------------------------------
$viewer = Join-Path $PSScriptRoot 'screen-viewer.ps1'
if (-not (Test-Path $viewer)) { Fail 'screen-viewer.ps1 not found next to this script.' }

# ParsecVDisplay.exe: env var, saved path, running process, then common folders.
$saved = Join-Path $env:USERPROFILE '.claude\modo-equipo\parsecvdisplay-path.txt'
$running = Get-Process ParsecVDisplay -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.Path }
$pvd = @(
  $env:PARSECVDISPLAY_EXE,
  $(if (Test-Path $saved) { (Get-Content $saved -Raw).Trim() }),
  $running,
  "$env:LOCALAPPDATA\Programs\ParsecVDisplay\ParsecVDisplay.exe",
  "$env:ProgramFiles\ParsecVDisplay\ParsecVDisplay.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
# Not found anywhere: ask the owner where it is (the skill never searches the disk or downloads).
if (-not $pvd -and -not (Test-Second)) {
  $ans = [Windows.Forms.MessageBox]::Show(
    "No second screen is available and ParsecVDisplay.exe could not be found.`n`nYes = pick ParsecVDisplay.exe now`nNo = open the viewer anyway`nCancel = do nothing",
    'Second screen viewer', 'YesNoCancel', 'Question')
  if ($ans -eq 'Cancel') { exit 0 }
  if ($ans -eq 'Yes') {
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Title = 'Select ParsecVDisplay.exe'
    $dlg.Filter = 'ParsecVDisplay.exe|ParsecVDisplay.exe|Programs (*.exe)|*.exe'
    if ($dlg.ShowDialog() -ne 'OK') { exit 0 }
    $pvd = $dlg.FileName
  }
}
if ($pvd -and $pvd -ne $running) { try { Set-Content -Path $saved -Value $pvd -ErrorAction Stop } catch {} }

# --- make sure a second screen exists ---------------------------------------------------
if (-not (Test-Second)) {
  if (-not $pvd) { & $viewer; exit 0 }   # owner chose to open the viewer without a second screen
  $proc = Get-Process ParsecVDisplay -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $proc) { Start-Process $pvd; Start-Sleep 2 }
  # Starting the exe again makes the running instance show its window.
  Start-Process $pvd
  $deadline = (Get-Date).AddSeconds(20)
  $add = $null
  while ((Get-Date) -lt $deadline -and -not $add) {
    Start-Sleep -Milliseconds 500
    $p = Get-Process ParsecVDisplay -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { continue }
    $cond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty, $p.Id)
    foreach ($w in [Windows.Automation.AutomationElement]::RootElement.FindAll('Children', $cond)) {
      $add = $w.FindFirst('Descendants', (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, 'xAdd')))
      if ($add) { break }
    }
  }
  if (-not $add) { Fail 'ParsecVDisplay did not show the ADD DISPLAY button.' }
  $pat = $null
  if ($add.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pat)) { $pat.Invoke() }
  else {
    # Fallback: invoke the inner button
    $btn = $add.FindFirst('Descendants', (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)))
    if ($btn -and $btn.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$pat)) { $pat.Invoke() }
    else { Fail 'Could not press ADD DISPLAY automatically.' }
  }
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Date) -lt $deadline -and -not (Test-Second)) { Start-Sleep -Milliseconds 500 }
  if (-not (Test-Second)) { Fail 'ADD DISPLAY was pressed but Windows reports no second screen.' }
  Start-Sleep 2
}

# --- open the viewer --------------------------------------------------------------------
& $viewer
