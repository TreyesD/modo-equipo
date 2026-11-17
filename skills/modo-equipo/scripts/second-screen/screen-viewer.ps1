Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Hide only the console window, so the viewer form itself stays visible
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Con {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
}
"@
[Con]::ShowWindow([Con]::GetConsoleWindow(), 0) | Out-Null

function Get-SecondScreen {
    [Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary } | Select-Object -First 1
}

$screen = Get-SecondScreen
if (-not $screen) {
    [Windows.Forms.MessageBox]::Show("No second screen found. Start ParsecVDisplay and add a display first.", "Screen viewer") | Out-Null
    exit 1
}

$form = New-Object Windows.Forms.Form
$form.Text = "Test screen (live)"
$form.TopMost = $true
$form.ShowInTaskbar = $true
$form.StartPosition = "Manual"
$form.Size = New-Object Drawing.Size(640, 400)
$primary = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object Drawing.Point(($primary.Right - 660), ($primary.Bottom - 440))
$form.BackColor = [Drawing.Color]::Black

$pic = New-Object Windows.Forms.PictureBox
$pic.Dock = "Fill"
$pic.SizeMode = "Zoom"
$form.Controls.Add($pic)

# Double-click toggles "always on top"
$pic.Add_DoubleClick({ $form.TopMost = -not $form.TopMost; $form.Text = "Test screen (live)" + $(if ($form.TopMost) { "" } else { " - not on top" }) })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    if ($form.WindowState -eq "Minimized") { return }
    $s = Get-SecondScreen
    if (-not $s) { $form.Text = "Test screen (display removed)"; return }
    $b = $s.Bounds
    $bmp = New-Object Drawing.Bitmap($b.Width, $b.Height)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
    $g.Dispose()
    $old = $pic.Image
    $pic.Image = $bmp
    if ($old) { $old.Dispose() }
})
$timer.Start()
$form.Add_FormClosed({ $timer.Stop() })

[Windows.Forms.Application]::Run($form)
