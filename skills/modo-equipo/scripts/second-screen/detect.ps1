# Prints one JSON object describing whether a second screen is available.
# Windows PowerShell 5.1+ only. Exit code is always 0; read the JSON.
$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName System.Windows.Forms
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
    } | ConvertTo-Json -Depth 4 -Compress
} catch {
    [pscustomobject]@{ ok = $false; secondScreen = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
}
