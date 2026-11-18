# Launcher for the touch viewer: makes sure a second screen exists, then opens screen-viewer.ps1
# from the same folder. The screen comes from the background screen keeper (parsec-vdd.ps1
# -Ensure), which talks to the installed Parsec Virtual Display Driver directly: no
# ParsecVDisplay window. The viewer is registered as a holder, so the screen stays while the
# viewer is open and for the keeper's idle time after it closes (tests may still need it); the
# keeper also keeps the mouse on the main screen. Only if the driver cannot be used does it fall
# back to starting the ParsecVDisplay app and pressing ADD DISPLAY.
# The screen belongs to a keeper session: -ScreenId <id>, else MODO_EQUIPO_SCREEN_ID, else the
# Claude Code session it was started from. Started from the desktop shortcut (no id at all) every
# launch gets a NEW virtual screen of its own (session "viewer-<pid>"), so tests that team
# sessions run on their own screens never land on the screen you are using. -NewScreen forces
# that. With several second screens the toolbar switches between them.
# -Smoke (developer check): runs the same -Ensure, opens the viewer in its -Smoke mode for a few
# seconds and prints the -Ensure result.
param([switch]$Smoke, [string]$ScreenId = '', [switch]$NewScreen)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, UIAutomationClient, UIAutomationTypes

function Test-Second { @([Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary }).Count -gt 0 }
function Fail($msg) { [void][Windows.Forms.MessageBox]::Show($msg, 'Second screen viewer', 'OK', 'Error'); exit 1 }

# --- locate files -----------------------------------------------------------------------
$viewer = Join-Path $PSScriptRoot 'screen-viewer.ps1'
if (-not (Test-Path $viewer)) { Fail 'screen-viewer.ps1 not found next to this script.' }
$viewerArgs = @{}
if ($Smoke) { $viewerArgs = @{ Smoke = $true } }

# --- 1. ask the screen keeper for a second screen (silent) --------------------------------
# Also when a screen already exists: registering the viewer as a holder turns on the mouse lock
# for a virtual screen and keeps the screen while the viewer is open.
$directError = $null
$module = Join-Path $PSScriptRoot 'parsec-vdd.ps1'
if (Test-Path $module) {
  try {
    $ensureArgs = @('-Ensure', '-HolderPid', $PID)
    if ($NewScreen) { $ScreenId = "viewer-$PID" }
    elseif (-not $ScreenId -and -not $env:MODO_EQUIPO_SCREEN_ID -and -not $env:CLAUDE_CODE_SESSION_ID) { $ScreenId = "viewer-$PID" }   # desktop shortcut
    if ($ScreenId) { $ensureArgs += @('-ScreenId', $ScreenId) }
    $json = & $module @ensureArgs
    $r = "$json" | ConvertFrom-Json
    if ($Smoke) { "smoke: ensure $json" }
    if ($r.ok) {
        $viewerArgs['Screen'] = $r.screen
        if ($r.id -and -not $r.shared) { $viewerArgs['ScreenId'] = $r.id }
        Start-Sleep -Milliseconds 500; & $viewer @viewerArgs; exit 0
    }
    $directError = $r.error
    # A crashed driver is not fixed by the ParsecVDisplay app (it hangs against it): say what to do.
    if ($r.driverOffline -and -not (Test-Second)) { Fail $r.error }
  } catch {
    if ($Smoke) { throw }
    $directError = $_.Exception.Message
  }
} else { $directError = 'parsec-vdd.ps1 not found next to this script.' }
if (Test-Second) { & $viewer @viewerArgs; exit 0 }   # e.g. a real monitor, keeper unusable

# --- 2. fallback: the ParsecVDisplay app -------------------------------------------------
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
