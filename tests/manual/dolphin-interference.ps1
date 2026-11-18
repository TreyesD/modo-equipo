param(
    [Parameter(Mandatory)][string]$DolphinDir,
    [Parameter(Mandatory)][string]$Rom,
    [string]$Log = (Join-Path $env:TEMP 'modo-equipo-dolphin-interference.log'),
    [string]$Work = (Join-Path $env:TEMP 'modo-equipo-dolphin-test'),
    [int]$Cycles = 4
)
# Does adding and removing other sessions' virtual screens disturb a Dolphin that runs on its
# own screen? Manual test (it really adds and removes displays and runs Dolphin).
#   - Its own Dolphin: a copy of $DolphinDir under another file name (so "taskkill /IM Dolphin.exe"
#     elsewhere never hits it, and this test never touches anyone else's Dolphin), with its own
#     user folder, no audio output, frame dumps as images.
#   - Dolphin is started with launch_offscreen.py on session 'dolphin-a' (its own screen A) of an
#     isolated keeper (MODO_EQUIPO_KEEPER_TAG=stress).
#   - While it runs, sessions B and C get new screens and release them again, $Cycles times.
#   - A sampler records every 250 ms where Dolphin's windows are and how many frames it dumped.
# Pass when Dolphin stays alive, its windows never leave screen A, frames keep coming (no gap over
# 2 s) and the dumped frames are valid images of one size. Stops first if a Dolphin or Godot that
# this test did not start is running. Exit 0 = pass.

$ErrorActionPreference = 'Stop'
$env:MODO_EQUIPO_KEEPER_TAG = 'stress'
$env:MODO_EQUIPO_SCREEN_ID = ''
$sdir = Join-Path $PSScriptRoot '..\..\skills\modo-equipo\scripts\second-screen' | Resolve-Path | Select-Object -ExpandProperty Path
$vddScript = Join-Path $sdir 'parsec-vdd.ps1'
. $vddScript
[void][ModoEquipo.CursorLock]::SetProcessDpiAwarenessContext([IntPtr](-4))
Add-Type -AssemblyName System.Drawing
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:fail = 0
Set-Content -Path $Log -Value "$(Get-Date -Format s) Dolphin interference test (cycles=$Cycles)"
function Note($t) {
    $line = "$(Get-Date -Format 'HH:mm:ss.fff') $t"
    for ($i = 0; $i -lt 20; $i++) { try { [IO.File]::AppendAllText($Log, "$line`r`n"); break } catch { Start-Sleep -Milliseconds 50 } }   # the log may be read meanwhile
    Write-Output $line
}
function Check([bool]$ok, [string]$what) { if ($ok) { Note "PASS $what" } else { $script:fail++; Note "FAIL $what" } }
function Keeper([string[]]$a) {
    $out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $vddScript @a
    $line = @($out | Where-Object { $_ -match '^\{' } | Select-Object -Last 1)
    if ($line) { try { return ($line[0] | ConvertFrom-Json) } catch {} }
    return $null
}
$script:dolphinPid = 0
function Foreign { @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(Dolphin|Godot)' -and $_.Id -ne $script:dolphinPid }) }
function Finish([int]$code) {
    if (Test-Path $stopFile) { } else { try { Set-Content $stopFile '1' } catch {} }
    if ($script:dolphinPid) { Stop-Process -Id $script:dolphinPid -Force -ErrorAction SilentlyContinue; Note "stopped the test Dolphin (pid $script:dolphinPid)" }
    $null = Keeper @('-Release')
    Note "result: $script:fail failed check(s); exit $code"
    exit $code
}

New-Item -ItemType Directory -Force -Path $Work | Out-Null
$stopFile = Join-Path $Work 'sampler.stop'
Remove-Item $stopFile -ErrorAction SilentlyContinue
$f = Foreign
if ($f.Count) { Note "STOP: Dolphin/Godot not started by this test is running ($(($f | ForEach-Object { "$($_.Name)#$($_.Id)" }) -join ', ')); run it again later"; exit 3 }

# --- own Dolphin copy and user folder -----------------------------------------------------------
$app = Join-Path $Work 'app'
$exe = Join-Path $app 'ModoEquipoTestDolphin.exe'
if (-not (Test-Path $exe)) {
    Copy-Item -Path $DolphinDir -Destination $app -Recurse -Force
    Rename-Item -Path (Join-Path $app 'Dolphin.exe') -NewName 'ModoEquipoTestDolphin.exe'
}
$user = Join-Path $Work 'user'
Remove-Item $user -Recurse -Force -ErrorAction SilentlyContinue
$cfg = Join-Path $user 'Config'
New-Item -ItemType Directory -Force -Path $cfg | Out-Null
Set-Content -Path (Join-Path $cfg 'Dolphin.ini') -Value @'
[Interface]
UsePanicHandlers = False
ConfirmStop = False
ShowSplashScreen = False
[Display]
RenderToMain = False
Fullscreen = False
[DSP]
Backend = No Audio Output
[Movie]
DumpFrames = True
[Analytics]
PermissionAsked = True
Enabled = False
[AutoUpdate]
UpdateTrack =
'@
Set-Content -Path (Join-Path $cfg 'GFX.ini') -Value @'
[Settings]
DumpFramesAsImages = True
InternalResolution = 1
'@
$frames = Join-Path $user 'Dump\Frames'

try {
# --- start it on its own screen -------------------------------------------------------------
$py = (Get-Command py -ErrorAction SilentlyContinue) ; $pyArgs = @('-3', '-I')
if (-not $py) { $py = Get-Command python; $pyArgs = @('-I') }
$launch = & $py.Source @pyArgs (Join-Path $sdir 'launch_offscreen.py') --screen-id dolphin-a --timeout 40 --keep-watch 15 -- $exe -u $user -b -e $Rom
$lj = $launch | Where-Object { $_ -match '^\{' } | Select-Object -Last 1 | ConvertFrom-Json
Note "launch: $($launch | Select-Object -Last 1)"
if (-not $lj -or -not $lj.ok) { $script:fail++; Note 'FAIL Dolphin was not placed on its own screen'; Finish 1 }
$script:dolphinPid = [int]$lj.pid
$screenA = $lj.screen.name
$st = Keeper @('-Status')
Check ([bool](@($st.sessions | Where-Object { $_.id -eq 'dolphin-a' -and $_.device -eq $screenA }).Count)) "launch: Dolphin runs on session dolphin-a's own screen $screenA"

# --- sampler ------------------------------------------------------------------------------------
$samples = Join-Path $Work 'samples.csv'
$sampler = Start-Job -ArgumentList $script:dolphinPid, $frames, $samples, $stopFile, $screenA -ScriptBlock {
    param($dpid, $frames, $out, $stop, $screenA)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class Wn {
    delegate bool P(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(P p, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out R r);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    public static string Rects(uint pid) {
        var l = new List<string>();
        EnumWindows((h, x) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) { R r; GetWindowRect(h, out r); l.Add(r.L + ":" + r.T + ":" + r.Rt + ":" + r.B + (IsIconic(h) ? ":min" : "")); } return true; }, IntPtr.Zero);
        return string.Join(" ", l);
    }
    public static uint ForegroundPid() { uint p; GetWindowThreadProcessId(GetForegroundWindow(), out p); return p; }
}
'@
    [Wn]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
    $field = [Windows.Forms.Screen].GetField('screens', [Reflection.BindingFlags]'NonPublic,Static')
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Set-Content -Path $out -Value 'ms,alive,frames,screenA,windows,screens,foreground'
    while (-not (Test-Path $stop)) {
        $field.SetValue($null, $null)
        $a = [Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq $screenA } | Select-Object -First 1
        $ab = if ($a) { "$($a.Bounds.X):$($a.Bounds.Y):$($a.Bounds.Right):$($a.Bounds.Bottom)" } else { 'gone' }
        $n = if (Test-Path $frames) { [IO.Directory]::GetFiles($frames, '*.png').Length } else { 0 }
        $alive = [bool](Get-Process -Id $dpid -ErrorAction SilentlyContinue)
        $fg = if ([Wn]::ForegroundPid() -eq $dpid) { 'dolphin' } else { 'other' }
        Add-Content -Path $out -Value "$($sw.ElapsedMilliseconds),$alive,$n,$ab,$([Wn]::Rects($dpid)),$([Windows.Forms.Screen]::AllScreens.Count),$fg"
        Start-Sleep -Milliseconds 250
    }
}

# Wait for the game to render.
$deadline = (Get-Date).AddSeconds(60)
do { Start-Sleep 1; $n = if (Test-Path $frames) { [IO.Directory]::GetFiles($frames, '*.png').Length } else { 0 } } while ($n -lt 120 -and (Get-Date) -lt $deadline)
Check ($n -ge 120) "render: Dolphin dumped $n frames before the screen changes"
if ($n -lt 120) { Finish 1 }
$t0 = Get-Date
Start-Sleep 5

# --- other sessions' screens come and go ---------------------------------------------------
# Real topology changes next to Dolphin's screen: extra displays are added and removed straight
# through the driver (the keeper itself keeps freed displays as spares, so it would not remove).
$vddB = [ModoEquipo.ParsecVdd]::Open()
try {
    for ($c = 1; $c -le $Cycles; $c++) {
        $before = @(Get-ScreenList | ForEach-Object { $_.Name })
        $ib = $vddB.AddDisplay(); $nb = Wait-NewScreen $before 10000
        $before2 = @(Get-ScreenList | ForEach-Object { $_.Name })
        $ic = $vddB.AddDisplay(); $nc = Wait-NewScreen $before2 10000
        Note "cycle $c : added B=$($nb.Name) at $($nb.Bounds.X),$($nb.Bounds.Y) C=$($nc.Name) at $($nc.Bounds.X),$($nc.Bounds.Y) (adds took $($vddB.LastAddAttempts) try)"
        Start-Sleep 3
        $vddB.RemoveDisplay($ib); $vddB.RemoveDisplay($ic)
        Note "cycle $c : removed B and C"
        Start-Sleep 3
    }
} finally { $vddB.Dispose() }
Start-Sleep 5
Set-Content $stopFile '1'
Receive-Job -Job $sampler -Wait -AutoRemoveJob | Out-Null

# --- analysis ---------------------------------------------------------------------------------
$rows = @(Import-Csv $samples)
Note "sampler: $($rows.Count) samples over $([int]($rows[-1].ms / 1000)) s"
Check (-not @($rows | Where-Object { $_.alive -ne 'True' }).Count) "Dolphin stayed alive the whole time"
$off = @($rows | Where-Object {
    $a = $_.screenA -split ':'
    if ($a[0] -eq 'gone') { return $true }
    foreach ($w in ($_.windows -split ' ' | Where-Object { $_ })) {
        $r = $w -split ':'
        $cx = ([int]$r[0] + [int]$r[2]) / 2; $cy = ([int]$r[1] + [int]$r[3]) / 2
        if ($cx -lt [int]$a[0] -or $cx -ge [int]$a[2] -or $cy -lt [int]$a[1] -or $cy -ge [int]$a[3]) { return $true }
    }
    return $false
})
Check ($off.Count -eq 0) "Dolphin's windows stayed on screen A$(if ($off) { " (off in $($off.Count) samples, first at $($off[0].ms) ms: $($off[0].windows) vs A $($off[0].screenA))" })"
$moves = @($rows | Group-Object windows).Count
Note "Dolphin window positions seen: $moves ($(@($rows | Group-Object windows | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ' | '))"
$aMoves = @($rows | Group-Object screenA | ForEach-Object { "$($_.Name) x$($_.Count)" })
Note "screen A positions seen: $($aMoves -join ' | ')"
$fgHits = @($rows | Where-Object { $_.foreground -eq 'dolphin' }).Count
Check ($fgHits -eq 0) "Dolphin never took the focus ($fgHits samples in front)"
$gap = 0; $lastN = [int]$rows[0].frames; $lastMs = [int]$rows[0].ms
foreach ($r in $rows) { if ([int]$r.frames -gt $lastN) { $gap = [Math]::Max($gap, [int]$r.ms - $lastMs); $lastN = [int]$r.frames; $lastMs = [int]$r.ms } }
$gap = [Math]::Max($gap, [int]$rows[-1].ms - $lastMs)
$first = [int]$rows[0].frames; $lastF = [int]$rows[-1].frames; $secs = ([int]$rows[-1].ms - [int]$rows[0].ms) / 1000
Note "frames: $first -> $lastF in $([int]$secs) s ($([int](($lastF - $first) / [Math]::Max(1, $secs))) per second); longest stall $gap ms"
Check ($gap -le 2000) "frames kept coming while screens were added and removed (longest stall $gap ms)"
$files = @(Get-ChildItem $frames -Filter '*.png' | Sort-Object { [int]($_.BaseName -replace '\D', '') })
$pick = @($files | Where-Object { $_.LastWriteTime -ge $t0 } | Get-Random -Count ([Math]::Min(40, $files.Count)) -SetSeed 7)
$sizes = @{}; $broken = 0; $dark = 0
foreach ($fi in $pick) {
    try {
        $bm = New-Object Drawing.Bitmap($fi.FullName)
        $sizes["$($bm.Width)x$($bm.Height)"] = 1
        $sum = 0; for ($x = 0; $x -lt $bm.Width; $x += [Math]::Max(1, [int]($bm.Width / 16))) { for ($y = 0; $y -lt $bm.Height; $y += [Math]::Max(1, [int]($bm.Height / 16))) { $p = $bm.GetPixel($x, $y); $sum += $p.R + $p.G + $p.B } }
        if ($sum -eq 0) { $dark++ }
        $bm.Dispose()
    } catch { $broken++ }
}
Check ($broken -eq 0 -and $sizes.Count -eq 1) "frame dumps during the changes are valid images of one size ($($pick.Count) checked: $($sizes.Keys -join ','), $broken broken, $dark fully black)"
} catch {
    $script:fail++
    Note "ERROR $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
}
Finish $(if ($script:fail) { 1 } else { 0 })
