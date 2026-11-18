param([string]$Mode = 'main', [string]$Dir = '', [int]$Wait = 0)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$src = Get-Content 'E:\Claude\modo-equipo\skills\modo-equipo\scripts\second-screen\screen-viewer.ps1' -Raw
$cs = [regex]::Match($src, '(?s)Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing @"\r?\n(.*?)\r?\n"@').Groups[1].Value
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition $cs
$area = New-Object Drawing.Rectangle(-32000, -32000, 1920, 1080)   # a rectangle far outside every real screen: nothing visible
function St($n) { [SvAudio]::MuteStates(@($n)) -join ' ' }
function WaitFor($n, $want, $ms = 6000) { $t = [Diagnostics.Stopwatch]::StartNew(); while ($t.ElapsedMilliseconds -lt $ms) { if ((St $n) -match "=$want") { return $true }; Start-Sleep -m 200 }; return $false }
if ($Mode -eq 'main') {
  $a = Start-Process "$PSScriptRoot\mt\mutetarget.exe" -ArgumentList (-31900), (-31900) -PassThru     # inside the area
  $b = Start-Process "$PSScriptRoot\mt\mutetargetb.exe" -ArgumentList (-20000), (-20000) -PassThru    # elsewhere (another screen)
  try {
    Start-Sleep 2
    [void][SvAudio]::SetMute(@('mutetarget','mutetargetb'), $false); Start-Sleep -m 500   # clear a mute left by an earlier crash test
    "before: A=[$(St 'mutetarget')] B=[$(St 'mutetargetb')]"
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('svm-' + [guid]::NewGuid().ToString('N')); [SvAutoMute]::StateDir = $dir
    [SvAutoMute]::Start($area, $PID)
    "A muted after start: $(WaitFor 'mutetarget' 1)  A=[$(St 'mutetarget')]  B=[$(St 'mutetargetb')]  muted=$([SvAutoMute]::Muted -join ',') shared=$([SvAutoMute]::Shared -join ',') err=$([SvAutoMute]::LastError)"
    "restore file: $((Get-ChildItem $dir -ErrorAction SilentlyContinue | % Name) -join ',')"
    [SvAutoMute]::Stop()
    "after stop: A=[$(St 'mutetarget')] B=[$(St 'mutetargetb')] file left: $(@(Get-ChildItem $dir -ErrorAction SilentlyContinue).Count)"
    # crash: a child viewer mutes A, then is killed; Recover must put the sound back
    $child = Start-Process powershell -ArgumentList '-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Mode','child','-Dir',$dir -PassThru -WindowStyle Hidden
    Start-Sleep 1; "A muted by child: $(WaitFor 'mutetarget' 1 15000)"; Start-Sleep -m 600
    Stop-Process -Id $child.Id -Force; Start-Sleep -m 800
    "after child killed: A=[$(St 'mutetarget')] (stays muted: that is the crash case) files=$((Get-ChildItem $dir | % Name) -join ',')"
    "recover handled=$([SvAutoMute]::Recover($dir))  A=[$(St 'mutetarget')] files=$(@(Get-ChildItem $dir).Count)"
  } finally { Stop-Process -Id $a.Id, $b.Id -ErrorAction SilentlyContinue; Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
} else {
  [SvAutoMute]::StateDir = $Dir
  [SvAutoMute]::Start($area, $PID)
  Start-Sleep -Seconds 60
}
