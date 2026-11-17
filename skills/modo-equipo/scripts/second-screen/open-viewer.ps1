# Launcher for the touch viewer: makes sure a second screen exists, then opens screen-viewer.ps1
# from the same folder. The virtual screen is added by talking to the installed Parsec Virtual
# Display Driver directly (parsec-vdd.ps1): no ParsecVDisplay window. It lives while the viewer
# is open and is removed when the viewer closes. Only if the driver cannot be used does it fall
# back to starting the ParsecVDisplay app and pressing ADD DISPLAY.
# -Smoke (developer check): always adds a screen through the driver, even when one exists, opens
# the viewer in its -Smoke mode for a few seconds, then prints the screen count before/after.
param([switch]$Smoke)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, UIAutomationClient, UIAutomationTypes

function Test-Second { @([Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary }).Count -gt 0 }
function Fail($msg) { [void][Windows.Forms.MessageBox]::Show($msg, 'Second screen viewer', 'OK', 'Error'); exit 1 }

# --- locate files -----------------------------------------------------------------------
$viewer = Join-Path $PSScriptRoot 'screen-viewer.ps1'
if (-not (Test-Path $viewer)) { Fail 'screen-viewer.ps1 not found next to this script.' }

# --- 1. a second screen already exists: just open the viewer -----------------------------
$viewerArgs = @{}
if ($Smoke) { $viewerArgs = @{ Smoke = $true } }
if ((Test-Second) -and -not $Smoke) { & $viewer; exit 0 }

# --- 2. add the virtual screen through the driver (silent) -------------------------------
$directError = $null
$module = Join-Path $PSScriptRoot 'parsec-vdd.ps1'
if (Test-Path $module) {
  $vdd = $null
  try {
    . $module
    $before = [ModoEquipo.ParsecVdd]::MonitorCount()
    $vdd = [ModoEquipo.ParsecVdd]::Open()
    [void]$vdd.AddDisplay()
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and [ModoEquipo.ParsecVdd]::MonitorCount() -le $before) { Start-Sleep -Milliseconds 200 }
    if ([ModoEquipo.ParsecVdd]::MonitorCount() -le $before) { throw 'The driver added a display but Windows reports no new screen.' }
    Start-Sleep 1   # let Windows finish placing the new screen
  } catch {
    if ($Smoke) { throw }
    $directError = $_.Exception.Message
    if ($vdd) { $vdd.Dispose() }
    $vdd = $null
  }
  if ($vdd) {
    # The keep-alive thread pings the driver while the viewer runs; closing removes the screen.
    try { & $viewer @viewerArgs } finally { $vdd.Dispose() }
    if ($Smoke) {
      $deadline = (Get-Date).AddSeconds(15)
      while ((Get-Date) -lt $deadline -and [ModoEquipo.ParsecVdd]::MonitorCount() -gt $before) { Start-Sleep -Milliseconds 200 }
      "smoke: screens before=$before after-close=$([ModoEquipo.ParsecVdd]::MonitorCount())"
    }
    exit 0
  }
} else { $directError = 'parsec-vdd.ps1 not found next to this script.' }

# --- 3. fallback: the ParsecVDisplay app -------------------------------------------------
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
# Not found anywhere: ask the owner (the skill never searches the disk, downloads or installs).
if (-not $pvd) {
  $ans = [Windows.Forms.MessageBox]::Show(
    "No second screen is available.`n`nCould not add one through the Parsec Virtual Display Driver:`n$directError`n`nIf the driver is not installed, see references/second-screen.md (Option B) in the modo-equipo skill.`n`nYes = pick ParsecVDisplay.exe instead`nNo = open the viewer anyway`nCancel = do nothing",
    'Second screen viewer', 'YesNoCancel', 'Question')
  if ($ans -eq 'Cancel') { exit 0 }
  if ($ans -eq 'No') { & $viewer; exit 0 }
  $dlg = New-Object Windows.Forms.OpenFileDialog
  $dlg.Title = 'Select ParsecVDisplay.exe'
  $dlg.Filter = 'ParsecVDisplay.exe|ParsecVDisplay.exe|Programs (*.exe)|*.exe'
  if ($dlg.ShowDialog() -ne 'OK') { exit 0 }
  $pvd = $dlg.FileName
}
if ($pvd -ne $running) { try { Set-Content -Path $saved -Value $pvd -ErrorAction Stop } catch {} }

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
if (-not $add) { Fail "Direct driver access failed ($directError) and ParsecVDisplay did not show the ADD DISPLAY button." }
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

# --- open the viewer --------------------------------------------------------------------
& $viewer
