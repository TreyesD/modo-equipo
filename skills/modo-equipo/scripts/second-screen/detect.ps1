param([switch]$Ensure, [switch]$NoEnsure, [string]$ScreenId = '')
# Prints one JSON object describing whether a second screen is available.
# By default it only LOOKS: it never adds a monitor (adding or removing one makes Windows rebuild
# the display topology, which can flash every screen), and "screen" is the first second screen.
# -Ensure [-ScreenId <id>] first asks the screen keeper (parsec-vdd.ps1 -Ensure) for this
# session's own screen (-ScreenId, else MODO_EQUIPO_SCREEN_ID, else the Claude Code session, else
# 'default'); "screen" then names it. -NoEnsure is accepted and means the default.
# Windows PowerShell 5.1+ only. Exit code is always 0; read the JSON.
$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName System.Windows.Forms
    $keeperResult = $null
    $keeper = Join-Path $PSScriptRoot 'parsec-vdd.ps1'
    if ($Ensure -and -not $NoEnsure -and $env:MODO_EQUIPO_NO_SECOND_SCREEN -ne '1' -and (Test-Path $keeper)) {
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
