# Creates a desktop shortcut that opens the touch viewer (and adds the virtual second screen
# first when there is none). Run it once, by hand; it copies the two scripts to a stable
# folder so the shortcut keeps working after plugin updates.
$dest = Join-Path $env:USERPROFILE '.claude\modo-equipo\viewer'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'open-viewer.ps1'), (Join-Path $PSScriptRoot 'screen-viewer.ps1') -Destination $dest -Force
$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Visor segunda pantalla.lnk'
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$s.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$s.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$dest\open-viewer.ps1`""
$s.IconLocation = "$env:WINDIR\System32\imageres.dll,109"
$s.WorkingDirectory = $env:USERPROFILE
$s.Save()
Write-Output "Shortcut created: $lnk"
