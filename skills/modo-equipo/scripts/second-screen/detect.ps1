param([switch]$NoEnsure)
# Prints one JSON object describing whether a second screen is available.
# When there is none and the Parsec Virtual Display Driver is installed, it first asks the screen
# keeper (parsec-vdd.ps1 -Ensure) for a virtual one, which stays for the keeper's idle time
# (launchers then register their programs as holders). -NoEnsure only looks.
# Windows PowerShell 5.1+ only. Exit code is always 0; read the JSON.
$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName System.Windows.Forms
    $keeperResult = $null
    $keeper = Join-Path $PSScriptRoot 'parsec-vdd.ps1'
    $hasSecond = @([Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary }).Count -gt 0
    if (-not $hasSecond -and -not $NoEnsure -and $env:MODO_EQUIPO_NO_SECOND_SCREEN -ne '1' -and (Test-Path $keeper)) {
        try { $keeperResult = ("$(& $keeper -Ensure)" | ConvertFrom-Json) } catch {}
        [Windows.Forms.Screen].GetField('screens', [Reflection.BindingFlags]'NonPublic,Static').SetValue($null, $null)
    }
    $screens = @([Windows.Forms.Screen]::AllScreens | ForEach-Object {
        [pscustomobject]@{
            name    = $_.DeviceName
            primary = $_.Primary
            x       = $_.Bounds.X
            y       = $_.Bounds.Y
            width   = $_.Bounds.Width
            height  = $_.Bounds.Height
        }
    })
    $second = @($screens | Where-Object { -not $_.primary })
    # Test switch: pretend there is no second screen.
    if ($env:MODO_EQUIPO_NO_SECOND_SCREEN -eq '1') { $second = @() }
    [pscustomobject]@{
        ok           = $true
        secondScreen = ($second.Count -gt 0)
        screenCount  = $screens.Count
        screens      = $screens
        keeper       = $(if ($keeperResult) { $keeperResult.keeper } else { $null })
    } | ConvertTo-Json -Depth 4 -Compress
} catch {
    [pscustomobject]@{ ok = $false; secondScreen = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
}
