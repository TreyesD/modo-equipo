param(
    [switch]$SelfTest
)
# Live, touch-style view of the second screen, shown on the main screen.
# Click, right-click, middle-click, drag and mouse wheel inside the image are replayed at the
# same spot on the second screen; the real cursor jumps there for a few milliseconds and comes
# back. A click on a window there gives it keyboard focus, so typing goes to it.
# -SelfTest runs the coordinate-mapping checks without opening any window (exit code 0 = pass).

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class SvNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, int data, UIntPtr extra);
}
"@
# Physical pixels on every monitor. With mixed scaling (for example 125% main screen and a
# 100% virtual screen) a system-DPI-aware process sees the second screen at the wrong size,
# so per-monitor awareness is required for clicks to land where the image shows.
function Set-PerMonitorDpi {
    try { if ([SvNative]::SetProcessDpiAwarenessContext([IntPtr](-4))) { return 'per-monitor-v2' } } catch {}
    try { if ([SvNative]::SetProcessDpiAwareness(2) -eq 0) { return 'per-monitor' } } catch {}
    try { if ([SvNative]::SetProcessDPIAware()) { return 'system' } } catch {}
    return 'unaware'
}
$script:dpiMode = Set-PerMonitorDpi

# Map a point inside a PictureBox in Zoom mode to screen coordinates.
# Returns $null when the point falls on the letterbox bars around the image.
function Convert-ViewToScreen([double]$px, [double]$py, [double]$boxW, [double]$boxH, $bounds) {
    $scale = [Math]::Min($boxW / $bounds.Width, $boxH / $bounds.Height)
    if ($scale -le 0) { return $null }
    $offX = ($boxW - $bounds.Width * $scale) / 2
    $offY = ($boxH - $bounds.Height * $scale) / 2
    $rx = ($px - $offX) / $scale
    $ry = ($py - $offY) / $scale
    if ($rx -lt 0 -or $ry -lt 0 -or $rx -ge $bounds.Width -or $ry -ge $bounds.Height) { return $null }
    return [pscustomobject]@{ X = [int]($bounds.X + $rx); Y = [int]($bounds.Y + $ry) }
}

if ($SelfTest) {
    $b = [pscustomobject]@{ X = 1920; Y = 0; Width = 1920; Height = 1080 }
    $cases = @(
        @{ In = @(320, 180, 640, 360); Want = @(2880, 540) },   # center, exact fit
        @{ In = @(0, 0, 640, 360);     Want = @(1920, 0) },     # top-left corner
        @{ In = @(320, 240, 640, 480); Want = @(2880, 540) },   # center with letterbox bars
        @{ In = @(320, 10, 640, 480);  Want = $null },          # on the top bar
        @{ In = @(-5, 100, 640, 360);  Want = $null }           # outside the box
    )
    $fail = 0
    foreach ($c in $cases) {
        $r = Convert-ViewToScreen $c.In[0] $c.In[1] $c.In[2] $c.In[3] $b
        $ok = if ($null -eq $c.Want) { $null -eq $r } else { $r -and $r.X -eq $c.Want[0] -and $r.Y -eq $c.Want[1] }
        if (-not $ok) { $fail++; Write-Output "FAIL in=$($c.In -join ',') got=$($r.X),$($r.Y)" }
    }
    Write-Output "selftest: $($cases.Count - $fail)/$($cases.Count) passed"
    exit $fail
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Hide only the console window, so the viewer form itself stays visible.
[SvNative]::ShowWindow([SvNative]::GetConsoleWindow(), 0) | Out-Null

function Get-SecondScreen {
    [Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary } | Select-Object -First 1
}

$screen = Get-SecondScreen
if (-not $screen) {
    [Windows.Forms.MessageBox]::Show("No second screen found. Connect a monitor or add a virtual display first.", "Screen viewer") | Out-Null
    exit 1
}

# Optional event log for troubleshooting: set MODO_EQUIPO_VIEWER_LOG to a file path.
function Write-ViewerLog($text) {
    if ($env:MODO_EQUIPO_VIEWER_LOG) {
        Add-Content -Path $env:MODO_EQUIPO_VIEWER_LOG -Value "$(Get-Date -Format 'HH:mm:ss.fff') $text"
    }
}

$BUTTON_FLAGS = @{
    'Left'   = @(0x0002, 0x0004)
    'Right'  = @(0x0008, 0x0010)
    'Middle' = @(0x0020, 0x0040)
}

# Replay a press at $from and a release at $to on the real screen, then put the cursor back.
function Send-Replay($button, $from, $to) {
    $flags = $BUTTON_FLAGS[$button]
    if (-not $flags) { return }
    $saved = [Windows.Forms.Cursor]::Position
    [SvNative]::SetCursorPos($from.X, $from.Y) | Out-Null
    Start-Sleep -Milliseconds 15
    [SvNative]::mouse_event($flags[0], 0, 0, 0, [UIntPtr]::Zero)
    if ($to.X -ne $from.X -or $to.Y -ne $from.Y) {
        # Drag: move in a few steps so the target sees a real drag.
        for ($i = 1; $i -le 8; $i++) {
            $x = [int]($from.X + ($to.X - $from.X) * $i / 8)
            $y = [int]($from.Y + ($to.Y - $from.Y) * $i / 8)
            [SvNative]::SetCursorPos($x, $y) | Out-Null
            Start-Sleep -Milliseconds 10
        }
    }
    [SvNative]::mouse_event($flags[1], 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 15
    [SvNative]::SetCursorPos($saved.X, $saved.Y) | Out-Null
}

function Send-Wheel($at, $delta) {
    $saved = [Windows.Forms.Cursor]::Position
    [SvNative]::SetCursorPos($at.X, $at.Y) | Out-Null
    Start-Sleep -Milliseconds 15
    [SvNative]::mouse_event(0x0800, 0, 0, $delta, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 15
    [SvNative]::SetCursorPos($saved.X, $saved.Y) | Out-Null
}

$form = New-Object Windows.Forms.Form
$form.Text = "Test screen (live, touch)"
$form.TopMost = $true
$form.ShowInTaskbar = $true
$form.StartPosition = "Manual"
# Per-monitor awareness turns off automatic scaling: size the window by the main screen's scale.
$probe = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$k = [Math]::Max(1.0, $probe.DpiX / 96.0)
$probe.Dispose()
$form.Size = New-Object Drawing.Size([int](640 * $k), [int](430 * $k))
$primary = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object Drawing.Point(($primary.Right - $form.Width - [int](20 * $k)), ($primary.Bottom - $form.Height - [int](20 * $k)))
Write-ViewerLog "start dpi=$($script:dpiMode) scale=$k second=$($screen.Bounds)"
$form.BackColor = [Drawing.Color]::Black
$form.KeyPreview = $true

$bar = New-Object Windows.Forms.Panel
$bar.Dock = "Top"
$bar.Height = [int](26 * $k)
$bar.BackColor = [Drawing.Color]::FromArgb(32, 32, 32)
$onTop = New-Object Windows.Forms.CheckBox
$onTop.Text = "Always on top"
$onTop.Checked = $true
$onTop.ForeColor = [Drawing.Color]::White
$onTop.AutoSize = $true
$onTop.Location = New-Object Drawing.Point([int](6 * $k), [int](4 * $k))
$onTop.Add_CheckedChanged({ $form.TopMost = $onTop.Checked })
$hint = New-Object Windows.Forms.Label
$hint.Text = "Click, drag or scroll on the image to use the second screen"
$hint.ForeColor = [Drawing.Color]::Silver
$hint.AutoSize = $true
$hint.Location = New-Object Drawing.Point(($onTop.Left + $onTop.PreferredSize.Width + [int](12 * $k)), [int](6 * $k))
$bar.Controls.Add($onTop)
$bar.Controls.Add($hint)

$pic = New-Object Windows.Forms.PictureBox
$pic.Dock = "Fill"
$pic.SizeMode = "Zoom"
$pic.Cursor = [Windows.Forms.Cursors]::Hand
$form.Controls.Add($pic)
$form.Controls.Add($bar)

$script:down = $null
$script:downButton = $null

function Get-Target($e) {
    $s = Get-SecondScreen
    if (-not $s) { return $null }
    Convert-ViewToScreen $e.X $e.Y $pic.ClientSize.Width $pic.ClientSize.Height $s.Bounds
}

$pic.Add_MouseDown({
    param($sender, $e)
    $script:down = Get-Target $e
    $script:downButton = "$($e.Button)"
    Write-ViewerLog "down $($script:downButton) view=$($e.X),$($e.Y) target=$($script:down.X),$($script:down.Y)"
})
$pic.Add_MouseUp({
    param($sender, $e)
    $from = $script:down
    $script:down = $null
    if (-not $from -or "$($e.Button)" -ne $script:downButton) { return }
    $to = Get-Target $e
    if (-not $to) { $to = $from }
    # Ignore tiny jitter so a click is not turned into a drag.
    if ([Math]::Abs($to.X - $from.X) -le 3 -and [Math]::Abs($to.Y - $from.Y) -le 3) { $to = $from }
    Write-ViewerLog "replay $($script:downButton) from=$($from.X),$($from.Y) to=$($to.X),$($to.Y)"
    Send-Replay $script:downButton $from $to
})
$form.Add_MouseWheel({
    param($sender, $e)
    $p = $pic.PointToClient([Windows.Forms.Cursor]::Position)
    $s = Get-SecondScreen
    if (-not $s) { return }
    $at = Convert-ViewToScreen $p.X $p.Y $pic.ClientSize.Width $pic.ClientSize.Height $s.Bounds
    if ($at) { Send-Wheel $at $e.Delta }
})

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    if ($form.WindowState -eq "Minimized") { return }
    $s = Get-SecondScreen
    if (-not $s) { $form.Text = "Test screen (display removed)"; return }
    $form.Text = "Test screen (live, touch)"
    $b = $s.Bounds
    $bmp = New-Object Drawing.Bitmap($b.Width, $b.Height)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
    # Screen captures do not include the cursor: draw a marker where it is on that screen.
    $c = [Windows.Forms.Cursor]::Position
    if ($b.Contains($c)) {
        $r = [Math]::Max(8, [int]($b.Width / 120))
        $g.FillEllipse([Drawing.Brushes]::Red, $c.X - $b.X - $r, $c.Y - $b.Y - $r, 2 * $r, 2 * $r)
    }
    $g.Dispose()
    $old = $pic.Image
    $pic.Image = $bmp
    if ($old) { $old.Dispose() }
})
$timer.Start()
$form.Add_FormClosed({ $timer.Stop() })

[Windows.Forms.Application]::Run($form)
