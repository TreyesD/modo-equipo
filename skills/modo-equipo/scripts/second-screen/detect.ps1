param([switch]$NoEnsure, [string]$ScreenId = '')
# Prints one JSON object describing whether a second screen is available.
# It first asks the screen keeper (parsec-vdd.ps1 -Ensure) for this session's own screen (the id
# is -ScreenId, else MODO_EQUIPO_SCREEN_ID, else 'default'); "screen" names it. That screen stays
# for the keeper's idle time (launchers then register their programs as holders). -NoEnsure only
# looks, and "screen" is then the first second screen.
# Windows PowerShell 5.1+ only. Exit code is always 0; read the JSON.
$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName System.Windows.Forms
    $keeperResult = $null
    $keeper = Join-Path $PSScriptRoot 'parsec-vdd.ps1'
    if (-not $NoEnsure -and $env:MODO_EQUIPO_NO_SECOND_SCREEN -ne '1' -and (Test-Path $keeper)) {
        $ensureArgs = @('-Ensure'); if ($ScreenId) { $ensureArgs += @('-ScreenId', $ScreenId) }
        try { $keeperResult = ("$(& $keeper @ensureArgs)" | ConvertFrom-Json) } catch {}
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
        screenId     = $(if ($keeperResult) { $keeperResult.id } else { $null })
        screen       = $(if ($second.Count -eq 0) { $null } elseif ($keeperResult -and $keeperResult.ok) { $keeperResult.screen } else { $second[0].name })
    } | ConvertTo-Json -Depth 4 -Compress
} catch {
    [pscustomobject]@{ ok = $false; secondScreen = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress
}
