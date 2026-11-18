param(
    [string]$Log = (Join-Path $env:TEMP 'modo-equipo-keeper-stress.log'),
    [int]$Cycles = 50,
    [ValidateRange(3, 7)][int]$Sessions = 4,
    [switch]$SkipLimit
)
# Stability test for the screen keeper and the Parsec Virtual Display Driver (manual: it really
# adds and removes virtual displays, so it is not part of the unit tests).
# It runs an isolated keeper (MODO_EQUIPO_KEEPER_TAG=stress) next to the normal one and only
# removes displays it added itself. Screens that existed before (the main screen, a real monitor,
# another keeper's virtual screen) must keep their name and position the whole time.
# Before every phase that removes displays it stops if a Dolphin or Godot process that this test
# did not start is running (Windows can move windows when monitors change).
# Phases: driver add/remove cycles, the driver's real display limit, concurrent sessions, keeper
# kill and restart, release of everything (no leaked display, mouse clip released).
# Exit 0 = every check passed. Every step goes to -Log.

$ErrorActionPreference = 'Stop'
$env:MODO_EQUIPO_KEEPER_TAG = 'stress'
$env:MODO_EQUIPO_SCREEN_ID = ''
$vddScript = Join-Path $PSScriptRoot '..\..\skills\modo-equipo\scripts\second-screen\parsec-vdd.ps1' | Resolve-Path | Select-Object -ExpandProperty Path
. $vddScript
[void][ModoEquipo.CursorLock]::SetProcessDpiAwarenessContext([IntPtr](-4))
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

$script:fail = 0
$script:mine = @()   # processes this test started
Set-Content -Path $Log -Value "$(Get-Date -Format s) keeper stress test (cycles=$Cycles sessions=$Sessions)"
function Note($t) {
    $line = "$(Get-Date -Format 'HH:mm:ss.fff') $t"
    for ($i = 0; $i -lt 20; $i++) { try { [IO.File]::AppendAllText($Log, "$line`r`n"); break } catch { Start-Sleep -Milliseconds 50 } }   # the log may be read meanwhile
    Write-Output $line
}
function Check([bool]$ok, [string]$what) { if ($ok) { Note "PASS $what" } else { $script:fail++; Note "FAIL $what" } }
function Layout { @(Get-ScreenList | ForEach-Object { "$($_.Name)@$($_.Bounds.X),$($_.Bounds.Y),$($_.Bounds.Width)x$($_.Bounds.Height)" }) }
function Foreign {
    $mine = @($script:mine | ForEach-Object { $_.Id })
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(Dolphin|Godot)' -and $mine -notcontains $_.Id })
}
function Guard([string]$phase) {
    $f = Foreign
    if ($f.Count) { Note "STOP before '$phase': $($f.Count) Dolphin/Godot process(es) not started by this test are running ($(($f | ForEach-Object { "$($_.Name)#$($_.Id)" }) -join ', ')); run it again later"; Finish 3 }
}
function Baseline-Intact([string]$when) {
    $now = Layout
    $missing = @($script:base | Where-Object { $now -notcontains $_ })
    Check ($missing.Count -eq 0) "$when : screens that existed before kept their name and position$(if ($missing) { " (changed: $($missing -join ' '))" })"
}
function Keeper([string[]]$a) {
    $out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $vddScript @a
    $line = @($out | Where-Object { $_ -match '^\{' } | Select-Object -Last 1)
    if ($line) { try { return ($line[0] | ConvertFrom-Json) } catch {} }
    return $null
}
function Holder { $p = Start-Process $ps -ArgumentList '-NoProfile -WindowStyle Hidden -Command Start-Sleep 3600' -WindowStyle Hidden -PassThru; $script:holders += $p; $p }
$script:holders = @()
function Finish([int]$code) {
    foreach ($p in $script:holders) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    $r = Keeper @('-Release')
    Start-Sleep 2
    $left = @(Get-ScreenList | Where-Object { $_.Virtual } | ForEach-Object { $_.Name } | Where-Object { $script:baseVirtual -notcontains $_ })
    if ($left.Count) { Note "cleanup: displays still there after the test: $($left -join ' ')" }
    Note "result: $script:fail failed check(s); exit $code"
    exit $code
}

$script:base = Layout
$script:baseVirtual = @(Get-ScreenList | Where-Object { $_.Virtual } | ForEach-Object { $_.Name })
$primary = @(Get-ScreenList | Where-Object { $_.Primary })[0]
Note "baseline: $($script:base -join ' | ')"
Note "driver version $(([ModoEquipo.ParsecVdd]::Open()).Version())"
if (Test-KeeperRunning) { Note 'a stress keeper from an earlier run is still there: releasing it'; $null = Keeper @('-Release') }

try {
# --- A. driver add/remove cycles --------------------------------------------------------------
Guard 'driver cycles'
$vdd = [ModoEquipo.ParsecVdd]::Open()
$times = @(); $bad = 0; $retried = 0; $maxTries = 1
for ($i = 1; $i -le $Cycles; $i++) {
    $before = @(Get-ScreenList | ForEach-Object { $_.Name })
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $idx = $vdd.AddDisplay()
    if ($vdd.LastAddAttempts -gt 1) { $retried++; $maxTries = [Math]::Max($maxTries, $vdd.LastAddAttempts) }
    $new = Wait-NewScreen $before 10000
    $tAdd = $sw.ElapsedMilliseconds
    if (-not $new) { $bad++; Note "cycle $i : index $idx added but Windows showed no new screen"; $vdd.RemoveDisplay($idx); continue }
    $vdd.RemoveDisplay($idx)
    $sw.Restart()
    do { Start-Sleep -Milliseconds 100; $gone = -not (@(Get-ScreenList | Where-Object { $_.Name -eq $new.Name }).Count) } while (-not $gone -and $sw.ElapsedMilliseconds -lt 10000)
    $times += $tAdd
    if (-not $gone) { $bad++; Note "cycle $i : $($new.Name) still there 10 s after remove" }
    if ($i % 10 -eq 0) { Note "cycle $i : index=$idx screen=$($new.Name) at $($new.Bounds.X),$($new.Bounds.Y) add=${tAdd}ms removed=$gone" ; Guard 'driver cycles' }
}
$vdd.Dispose()
Check ($bad -eq 0) "driver: $Cycles add/remove cycles, every display appeared and went away ($bad bad)"
Note "driver: the driver refused the first ADD in $retried of $Cycles cycles; the retry worked (most tries in one add: $maxTries)"
if ($times) { Note "driver: add to visible screen min=$(($times | Measure-Object -Minimum).Minimum) max=$(($times | Measure-Object -Maximum).Maximum) avg=$([int]($times | Measure-Object -Average).Average) ms" }
Check (([ModoEquipo.ParsecVdd]::MonitorCount()) -eq $script:base.Count) "driver: monitor count back to $($script:base.Count)"
Baseline-Intact 'after driver cycles'

# --- B. the driver's real display limit ------------------------------------------------------
if (-not $SkipLimit) {
    Guard 'display limit'
    $vdd = [ModoEquipo.ParsecVdd]::Open()
    $got = @(); $why = 'cap of 20 reached'
    for ($i = 1; $i -le 20; $i++) {
        try { $got += $vdd.AddDisplay() } catch { $why = $_.Exception.Message; break }
    }
    Start-Sleep 3
    $seen = @(Get-ScreenList | Where-Object { $_.Virtual }).Count
    Note "limit: the driver accepted $($got.Count) more display(s) (indexes $($got -join ',')); stopped: $why; Windows shows $seen virtual screen(s) in all"
    foreach ($x in $got) { $vdd.RemoveDisplay($x) }
    $vdd.Dispose()
    Start-Sleep 3
    Check (([ModoEquipo.ParsecVdd]::MonitorCount()) -eq $script:base.Count) "limit: all of them removed again"
    Baseline-Intact 'after the limit probe'
}

# --- C. concurrent sessions ------------------------------------------------------------------
$ids = @(1..$Sessions | ForEach-Object { "stress-$_" })
$hp = @{}; foreach ($id in $ids) { $hp[$id] = Holder }
# The first Ensure starts the keeper; the others arrive together while it runs.
$first = Keeper @('-Ensure', '-ScreenId', $ids[0], '-HolderPid', $hp[$ids[0]].Id, '-IdleMinutes', '1')
Check ([bool]($first -and $first.ok)) "sessions: '$($ids[0])' got $($first.screen) (keeper $($first.keeper))"
$jobs = @($ids | Select-Object -Skip 1 | ForEach-Object {
    $id = $_
    Start-Job -ScriptBlock { param($ps, $f, $id, $h) $env:MODO_EQUIPO_KEEPER_TAG = 'stress'; & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $f -Ensure -ScreenId $id -HolderPid $h -IdleMinutes 1 } -ArgumentList $ps, $vddScript, $id, $hp[$id].Id
})
$answers = @{ $ids[0] = $first }
foreach ($j in $jobs) { $o = Receive-Job -Job $j -Wait -AutoRemoveJob; $a = $o | Where-Object { $_ -match '^\{' } | Select-Object -Last 1 | ConvertFrom-Json; if ($a) { $answers[$a.id] = $a } }
foreach ($id in $ids) { $a = $answers[$id]; Check ([bool]($a -and $a.ok)) "sessions: '$id' -> $(if ($a) { "$($a.screen) at $($a.x),$($a.y) $($a.width)x$($a.height)" } else { 'no answer' })" }
$devs = @($answers.Values | Where-Object { $_.ok } | ForEach-Object { $_.screen })
Check (($devs | Select-Object -Unique).Count -eq $Sessions) "sessions: $Sessions sessions have $Sessions different screens"
Check (-not @($devs | Where-Object { $script:baseVirtual -contains $_ -or $_ -eq $primary.Name }).Count) "sessions: no session got the main screen or a screen that existed before"
$rects = @($answers.Values | Where-Object { $_.ok } | ForEach-Object { [Drawing.Rectangle]::new($_.x, $_.y, $_.width, $_.height) })
$overlap = $false; for ($a = 0; $a -lt $rects.Count; $a++) { for ($b = $a + 1; $b -lt $rects.Count; $b++) { if ($rects[$a].IntersectsWith($rects[$b])) { $overlap = $true } } }
Check (-not $overlap) "sessions: the new screens do not overlap each other"
Check (-not @($rects | Where-Object { $_.IntersectsWith($primary.Bounds) }).Count) "sessions: no new screen overlaps the main screen"
Baseline-Intact 'with all sessions'
$again = Keeper @('-Ensure', '-ScreenId', $ids[1])
Check ([bool]($again -and $again.screen -eq $answers[$ids[1]].screen -and $again.keeper -eq 'running')) "sessions: asking again for '$($ids[1])' gives the same screen ($($again.screen))"
$clip = [ModoEquipo.CursorLock]::Current(); $st = Keeper @('-Status')
Note "lock: keeper lock area $($st.lockArea); clip now $($clip.Left),$($clip.Top),$($clip.Right),$($clip.Bottom)"
Check ([bool]($st.lockArea -eq "$($primary.Bounds.Left),$($primary.Bounds.Top),$($primary.Bounds.Right),$($primary.Bounds.Bottom)" -or -not $st.lockOn)) "lock: the mouse area is the main screen with $Sessions virtual screens"

Guard 'session release'
$rel = Keeper @('-Release', '-ScreenId', $ids[2])
Start-Sleep 2
$still = @(Get-ScreenList | ForEach-Object { $_.Name })
$stR = Keeper @('-Status')
Check ([bool]($rel.ok -and -not @($stR.sessions | Where-Object { $_.id -eq $ids[2] }).Count)) "release: session '$($ids[2])' freed"
Check ($still -contains $answers[$ids[2]].screen) "release: its screen $($answers[$ids[2]].screen) is kept as a spare (no monitor removed, no flash)"
$spare = Keeper @('-Ensure', '-ScreenId', 'stress-spare', '-IdleMinutes', '1')
Check ([bool]($spare -and $spare.screen -eq $answers[$ids[2]].screen)) "release: a new session takes over the spare screen ($($spare.screen)) instead of adding a monitor"
Check (-not @($ids | Where-Object { $_ -ne $ids[2] } | Where-Object { $still -notcontains $answers[$_].screen }).Count) "release: the other sessions kept their screens"
$nowList = Get-ScreenList
$moved = @(foreach ($id in ($ids | Where-Object { $_ -ne $ids[2] })) {
    $dev = $answers[$id].screen
    $s = @($nowList | Where-Object { $_.Name -eq $dev })
    if ($s.Count -and ($s[0].Bounds.X -ne $answers[$id].x -or $s[0].Bounds.Y -ne $answers[$id].y)) { "$id ($($answers[$id].x),$($answers[$id].y) -> $($s[0].Bounds.X),$($s[0].Bounds.Y))" }
})
Note "release: sessions whose screen moved when another was removed: $(if ($moved) { $moved -join ', ' } else { 'none' })"
Baseline-Intact 'after one release'

# Holder dies: the session ends after its idle time (1 minute here).
$dead = $ids[$Sessions - 1]
Stop-Process -Id $hp[$dead].Id -Force
Note "idle: holder of '$dead' killed; waiting for the 1 minute idle time"
Guard 'idle expiry'
$deadline = (Get-Date).AddSeconds(100); $freed = $false
do { Start-Sleep 5; $st = Keeper @('-Status'); $freed = -not @($st.sessions | Where-Object { $_.id -eq $dead }).Count } while (-not $freed -and (Get-Date) -lt $deadline)
Check $freed "idle: the session of the dead holder was freed"
Check (@(Get-ScreenList | ForEach-Object { $_.Name }) -contains $answers[$dead].screen) "idle: its screen was kept as a spare, not removed"

# --- D. keeper killed and restarted ----------------------------------------------------------
Guard 'keeper kill'
$st = Keeper @('-Status')
$before = @($st.sessions)
Note "kill: keeper pid $($st.pid) with $($before.Count) session(s): $(($before | ForEach-Object { "$($_.id)=$($_.device)" }) -join ' ')"
Stop-Process -Id $st.pid -Force
Start-Sleep 3
$survived = @(Get-ScreenList | Where-Object { $_.Virtual } | ForEach-Object { $_.Name } | Where-Object { $script:baseVirtual -notcontains $_ })
$pinger = [bool](Get-Process ParsecVDisplay -ErrorAction SilentlyContinue)
Note "kill: displays still there after the kill: $(if ($survived) { $survived -join ' ' } else { 'none' }) (ParsecVDisplay app running: $pinger)"
Start-Sleep 1
$cl = [ModoEquipo.CursorLock]::Current(); $dk = [ModoEquipo.CursorLock]::Desktop()
Check ($cl.Left -eq $dk.Left -and $cl.Right -eq $dk.Right -and $cl.Top -eq $dk.Top -and $cl.Bottom -eq $dk.Bottom -or $st.lockArea -eq '') "kill: the mouse clip was released by the watchdog"
$back = Keeper @('-Ensure', '-ScreenId', $ids[0], '-IdleMinutes', '1')
Check ([bool]($back -and $back.ok -and $back.keeper -eq 'started')) "restart: a new keeper started for '$($ids[0])' -> $($back.screen)"
if ($survived -contains $answers[$ids[0]].screen) { Check ($back.screen -eq $answers[$ids[0]].screen) "restart: '$($ids[0])' got its old screen back" }
Start-Sleep 20   # unclaimed displays of the dead keeper go after 15 s
$st = Keeper @('-Status')
$extra = @(Get-ScreenList | Where-Object { $_.Virtual } | ForEach-Object { $_.Name } | Where-Object { $script:baseVirtual -notcontains $_ })
Note "restart: sessions now $(($st.sessions | ForEach-Object { "$($_.id)=$($_.device)" }) -join ' '); test displays $($extra -join ' ')"
Check ($extra.Count -le $survived.Count) "restart: no display added beyond the ones that survived the kill ($($extra.Count) now, $($survived.Count) survived)"
Baseline-Intact 'after the keeper restart'

# --- E. release everything ---------------------------------------------------------------------
Guard 'final release'
$r = Keeper @('-Release')
Start-Sleep 3
Check ([bool]($r -and $r.ok -and -not (Test-KeeperRunning))) "final: the keeper stopped"
$left = @(Get-ScreenList | Where-Object { $_.Virtual } | ForEach-Object { $_.Name } | Where-Object { $script:baseVirtual -notcontains $_ })
Check ($left.Count -eq 0) "final: no leaked display$(if ($left) { " ($($left -join ' '))" })"
Check (([ModoEquipo.ParsecVdd]::MonitorCount()) -eq $script:base.Count) "final: monitor count back to $($script:base.Count)"
Baseline-Intact 'at the end'
$p2 = @(Get-ScreenList | Where-Object { $_.Primary })[0]
Check ($p2.Name -eq $primary.Name -and $p2.Bounds -eq $primary.Bounds) "final: the main screen is unchanged ($($p2.Name) $($p2.Bounds))"
} catch {
    $script:fail++
    Note "ERROR $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
}
Finish $(if ($script:fail) { 1 } else { 0 })
