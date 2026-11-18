param(
    [string]$Root = (Get-Location).Path,
    [string]$ScreenId = ''
)
# Opens the test runner in its own window on this session's screen. With the screen keeper
# (parsec-vdd.ps1 -Ensure) each session id (-ScreenId, else MODO_EQUIPO_SCREEN_ID, else
# 'default') gets its own virtual monitor; the runner is registered as a holder so the screen
# stays until the tests end (plus the keeper's idle time). Without the keeper it uses the first
# second screen there is.
# Exit codes: 0 launched, 2 no second screen (nothing was started; run tests the normal way).
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class SsWin {
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
}
"@

$keeper = Join-Path $PSScriptRoot 'parsec-vdd.ps1'
function Get-Screen([string]$name) {
    [Windows.Forms.Screen].GetField('screens', [Reflection.BindingFlags]'NonPublic,Static').SetValue($null, $null)
    $all = [Windows.Forms.Screen]::AllScreens
    if ($name) { $all | Where-Object { $_.DeviceName -eq $name } | Select-Object -First 1 }
    else { $all | Where-Object { -not $_.Primary } | Select-Object -First 1 }
}
$second = $null
$ensureArgs = @{ Ensure = $true; HolderPid = @($PID) }   # a hashtable: an array would bind positionally
if ($ScreenId) { $ensureArgs['ScreenId'] = $ScreenId }
if ($env:MODO_EQUIPO_NO_SECOND_SCREEN -eq '1') { $second = $null }  # test switch
elseif (Test-Path $keeper) {
    $json = & $keeper @ensureArgs
    if ($LASTEXITCODE -eq 0) { try { $second = Get-Screen ("$json" | ConvertFrom-Json).screen } catch {} }
} else { $second = Get-Screen '' }
if (-not $second) {
    Write-Output 'NO_SECOND_SCREEN'
    exit 2
}

$runner = Join-Path $PSScriptRoot 'run-tests.ps1'
$p = Start-Process powershell -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner, '-Root', $Root

$deadline = (Get-Date).AddSeconds(10)
while ($p.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; $p.Refresh() }
$b = $second.Bounds
[SsWin]::MoveWindow($p.MainWindowHandle, $b.X + 40, $b.Y + 40, $b.Width - 80, $b.Height - 120, $true) | Out-Null
if (Test-Path $keeper) { $ensureArgs['HolderPid'] = @($p.Id); $null = & $keeper @ensureArgs }   # keep the screen while the runner lives
Write-Output "LAUNCHED pid=$($p.Id) screen=$($second.DeviceName)"
exit 0
