# Launcher for the touch viewer: makes sure a second screen exists, then opens screen-viewer.ps1
# from the same folder. The screen comes from the background screen keeper (parsec-vdd.ps1
# -Ensure), which talks to the installed Parsec Virtual Display Driver directly: no
# ParsecVDisplay window. The viewer is registered as a holder, so the screen stays while the
# viewer is open (a desktop-shortcut session, 'viewer-<pid>', turns into a spare as soon as the
# viewer closes, so reopening reuses it without adding a monitor; a named session keeps it for the
# keeper's idle time); the keeper also keeps the mouse on the main screen. The ParsecVDisplay app is never started; if the
# driver cannot be used, an error with the real reason is shown.
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
    $ensureArgs = @{ Ensure = $true; HolderPid = @($PID) }   # a hashtable: an array would bind positionally
    if ($NewScreen) { $ScreenId = "viewer-$PID" }
    elseif (-not $ScreenId -and -not $env:MODO_EQUIPO_SCREEN_ID -and -not $env:CLAUDE_CODE_SESSION_ID) { $ScreenId = "viewer-$PID" }   # desktop shortcut
    if ($ScreenId) { $ensureArgs['ScreenId'] = $ScreenId }
    $json = & $module @ensureArgs
    $r = "$json" | ConvertFrom-Json
    if ($Smoke) { "smoke: ensure $json" }
    # A crashed (offline) driver: offer to restart only that device (Windows may ask for admin
    # rights), then try once more.
    if (-not $r.ok -and $r.driverOffline -and -not $Smoke) {
        $ask = [Windows.Forms.MessageBox]::Show("$($r.error)`n`nRestart the virtual display driver now?", 'Second screen viewer', 'YesNo', 'Warning')
        if ($ask -eq 'Yes') {
            $fix = "$(& $module -RestartDriver)" | ConvertFrom-Json
            if (-not $fix.ok) { Fail "Could not restart the virtual display driver: $($fix.error)`n`n$($r.error)" }
            $json = & $module @ensureArgs
            $r = "$json" | ConvertFrom-Json
        }
    }
    if ($r.ok) {
        $viewerArgs['Screen'] = $r.screen
        if ($r.id -and -not $r.shared) { $viewerArgs['ScreenId'] = $r.id }
        Start-Sleep -Milliseconds 500; & $viewer @viewerArgs; exit 0
    }
    $directError = $r.error
    # A crashed driver is not fixed by the ParsecVDisplay app (it hangs against it): say what to do.
  } catch {
    if ($Smoke) { throw }
    $directError = $_.Exception.Message
  }
} else { $directError = 'parsec-vdd.ps1 not found next to this script.' }
if (Test-Second) { & $viewer @viewerArgs; exit 0 }   # e.g. a real monitor, keeper unusable

# The ParsecVDisplay app is never started: the driver is driven directly, and when that fails
# the real reason is shown instead.
Fail "No second screen is available.`n`n$directError"
