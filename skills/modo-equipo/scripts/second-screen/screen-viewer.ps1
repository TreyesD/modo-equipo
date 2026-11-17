param(
    [switch]$SelfTest,
    [switch]$Smoke,
    [int]$SmokeSeconds = 5
)
# Live, touch-style view of the second screen, shown on the main screen.
# Moving the pointer over the image puts the real cursor on the second screen (direct mode):
# clicks, drags, the wheel and typing are ordinary native input there. Push past any edge of the
# image, or press Ctrl+Alt+Q, to come back.
# While a virtual screen exists the real cursor is kept on the main screen(s): plain movement
# stops at the edge; holding a mouse button (dragging a window) or direct mode can still cross.
# The lock is released when the viewer closes and can be turned off from the toolbar.
# The picture comes from the Windows Magnification API (GPU, ~60 fps, real cursor shape); when it
# is not available the viewer falls back to a GDI screen copy.
# The window has no Windows title bar: a thin strip on top moves it, its edges resize it, and a
# floating toolbar (outside the window in small mode, auto-hidden at the top in full screen)
# holds always-on-top, pointer, mute, full screen, hide, minimize and close.
# -SelfTest runs the layout checks without opening any window (exit code 0 = pass).
# -Smoke opens the viewer on the second screen for a few seconds, without direct mode, and
# prints which renderer it used (developer check).

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

[StructLayout(LayoutKind.Sequential)] public struct SvPt { public int X; public int Y; }
[StructLayout(LayoutKind.Sequential)] public struct SvRect { public int Left; public int Top; public int Right; public int Bottom; }

public static class SvNative {
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(SvPt p);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint p);
    [DllImport("winmm.dll")] public static extern uint timeEndPeriod(uint p);
}

// Borderless window that can still be resized from its edges and moved from any control.
public class SvForm : Form {
    public int Grip = 6;
    public bool Resizable = true;
    public bool NoActivate = false;
    [DllImport("user32.dll")] static extern bool ReleaseCapture();
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    protected override bool ShowWithoutActivation { get { return NoActivate; } }
    public static void DragMove(Form f) { ReleaseCapture(); SendMessage(f.Handle, 0xA1, (IntPtr)2, IntPtr.Zero); }
    protected override void WndProc(ref Message m) {
        base.WndProc(ref m);
        if (m.Msg == 0x84 && Resizable && WindowState == FormWindowState.Normal) {
            long lp = m.LParam.ToInt64();
            Point p = PointToClient(new Point((short)(lp & 0xFFFF), (short)((lp >> 16) & 0xFFFF)));
            bool l = p.X < Grip, r = p.X >= ClientSize.Width - Grip, t = p.Y < Grip, b = p.Y >= ClientSize.Height - Grip;
            int hit = 0;
            if (t && l) hit = 13; else if (t && r) hit = 14; else if (b && l) hit = 16; else if (b && r) hit = 17;
            else if (l) hit = 10; else if (r) hit = 11; else if (t) hit = 12; else if (b) hit = 15;
            if (hit != 0) m.Result = (IntPtr)hit;
        }
    }
}

// Windows Magnification API: a child window that shows another screen area, drawn by the GPU.
public static class SvMag {
    [StructLayout(LayoutKind.Sequential)] struct MAGTRANSFORM { [MarshalAs(UnmanagedType.ByValArray, SizeConst = 9)] public float[] v; }
    [DllImport("Magnification.dll")] static extern bool MagInitialize();
    [DllImport("Magnification.dll")] static extern bool MagUninitialize();
    [DllImport("Magnification.dll")] static extern bool MagSetWindowSource(IntPtr h, SvRect r);
    [DllImport("Magnification.dll")] static extern bool MagSetWindowTransform(IntPtr h, ref MAGTRANSFORM t);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowEx(int ex, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr p);
    [DllImport("user32.dll")] static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
    [DllImport("user32.dll")] static extern bool InvalidateRect(IntPtr h, IntPtr r, bool erase);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string n);
    public static bool Init() { try { return MagInitialize(); } catch { return false; } }
    public static void Shutdown() { try { MagUninitialize(); } catch { } }
    // WS_CHILD | WS_VISIBLE, plus MS_SHOWMAGNIFIEDCURSOR when the cursor should be drawn.
    public static IntPtr Create(IntPtr parent, bool showCursor) {
        int style = 0x40000000 | 0x10000000 | (showCursor ? 1 : 0);
        return CreateWindowEx(0, "Magnifier", "SvMag", style, 0, 0, 1, 1, parent, IntPtr.Zero, GetModuleHandle(null), IntPtr.Zero);
    }
    public static bool Place(IntPtr h, int x, int y, int w, int hh, float scale) {
        MoveWindow(h, x, y, w, hh, true);
        MAGTRANSFORM t = new MAGTRANSFORM(); t.v = new float[9];
        t.v[0] = scale; t.v[4] = scale; t.v[8] = 1f;
        return MagSetWindowTransform(h, ref t);
    }
    public static bool Show(IntPtr h, int x, int y, int w, int hh) {
        SvRect r; r.Left = x; r.Top = y; r.Right = x + w; r.Bottom = y + hh;
        bool ok = MagSetWindowSource(h, r);
        InvalidateRect(h, IntPtr.Zero, false);
        return ok;
    }
    public static void SetCursorVisible(IntPtr h, bool on) {
        int s = GetWindowLong(h, -16);
        SetWindowLong(h, -16, on ? (s | 1) : (s & ~1));
        InvalidateRect(h, IntPtr.Zero, true);
    }
}

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class SvMMDeviceEnumerator { }
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISvMMDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int flow, int mask, out IntPtr devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int flow, int role, out ISvMMDevice device);
}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISvMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
}
[ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISvAudioSessionManager2 {
    [PreserveSig] int GetAudioSessionControl(IntPtr g, int flags, out IntPtr c);
    [PreserveSig] int GetSimpleAudioVolume(IntPtr g, int flags, out IntPtr v);
    [PreserveSig] int GetSessionEnumerator(out ISvAudioSessionEnumerator e);
}
[ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISvAudioSessionEnumerator {
    [PreserveSig] int GetCount(out int n);
    [PreserveSig] int GetSession(int i, out ISvAudioSessionControl2 s);
}
[ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISvAudioSessionControl2 {
    [PreserveSig] int GetState(out int s);
    [PreserveSig] int GetDisplayName(out IntPtr n);
    [PreserveSig] int SetDisplayName(IntPtr n, IntPtr g);
    [PreserveSig] int GetIconPath(out IntPtr p);
    [PreserveSig] int SetIconPath(IntPtr p, IntPtr g);
    [PreserveSig] int GetGroupingParam(out Guid g);
    [PreserveSig] int SetGroupingParam(IntPtr a, IntPtr b);
    [PreserveSig] int RegisterAudioSessionNotification(IntPtr n);
    [PreserveSig] int UnregisterAudioSessionNotification(IntPtr n);
    [PreserveSig] int GetSessionIdentifier(out IntPtr s);
    [PreserveSig] int GetSessionInstanceIdentifier(out IntPtr s);
    [PreserveSig] int GetProcessId(out uint pid);
    [PreserveSig] int IsSystemSoundsSession();
    [PreserveSig] int SetDuckingPreference(bool optOut);
}
[ComImport, Guid("87CE5498-68D6-44E5-9215-6F5E9AAF8B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface ISvSimpleAudioVolume {
    [PreserveSig] int SetMasterVolume(float level, ref Guid g);
    [PreserveSig] int GetMasterVolume(out float level);
    [PreserveSig] int SetMute(bool mute, ref Guid g);
    [PreserveSig] int GetMute(out bool mute);
}

// Mute the apps shown on the second screen (Windows has no per-screen mute).
public static class SvAudio {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out SvRect r);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);

    // Windows shell processes own the desktop and taskbar on every screen; never mute them.
    static readonly string[] Shell = { "explorer", "shellexperiencehost", "startmenuexperiencehost", "textinputhost", "applicationframehost", "searchhost", "searchapp" };

    // Process names of the visible windows whose center is on the given screen area.
    public static string[] ProcessNamesOn(int x, int y, int w, int h, int ownPid) {
        List<string> names = new List<string>();
        EnumWindows(delegate (IntPtr hw, IntPtr l) {
            if (!IsWindowVisible(hw) || IsIconic(hw) || GetWindowTextLength(hw) == 0) return true;
            SvRect r; if (!GetWindowRect(hw, out r)) return true;
            int cx = (r.Left + r.Right) / 2, cy = (r.Top + r.Bottom) / 2;
            if (cx < x || cx >= x + w || cy < y || cy >= y + h) return true;
            uint pid; GetWindowThreadProcessId(hw, out pid);
            if ((int)pid == ownPid || pid == 0) return true;
            try {
                string n = Process.GetProcessById((int)pid).ProcessName;
                if (Array.IndexOf(Shell, n.ToLowerInvariant()) < 0 && !names.Contains(n)) names.Add(n);
            } catch { }
            return true;
        }, IntPtr.Zero);
        return names.ToArray();
    }

    // Set mute on every audio session of the default output whose process name is in names.
    // Returns how many sessions were changed.
    public static int SetMute(string[] names, bool mute) {
        ISvMMDeviceEnumerator en = (ISvMMDeviceEnumerator)(new SvMMDeviceEnumerator());
        ISvMMDevice dev;
        Marshal.ThrowExceptionForHR(en.GetDefaultAudioEndpoint(0, 1, out dev));
        Guid iid = typeof(ISvAudioSessionManager2).GUID;
        object o;
        Marshal.ThrowExceptionForHR(dev.Activate(ref iid, 23, IntPtr.Zero, out o));
        ISvAudioSessionEnumerator se;
        Marshal.ThrowExceptionForHR(((ISvAudioSessionManager2)o).GetSessionEnumerator(out se));
        int n, changed = 0;
        se.GetCount(out n);
        for (int i = 0; i < n; i++) {
            ISvAudioSessionControl2 c;
            if (se.GetSession(i, out c) != 0 || c == null) continue;
            uint pid; c.GetProcessId(out pid);
            if (pid == 0) continue;
            string pn = "";
            try { pn = Process.GetProcessById((int)pid).ProcessName; } catch { continue; }
            foreach (string want in names) {
                if (string.Equals(want, pn, StringComparison.OrdinalIgnoreCase)) {
                    Guid g = Guid.Empty;
                    ((ISvSimpleAudioVolume)c).SetMute(mute, ref g);
                    changed++;
                    break;
                }
            }
        }
        return changed;
    }
}

// Keeps the real cursor on the main screen(s) while a virtual screen exists: plain movement
// stops at the edge, while a held button (dragging a window) or the viewer's direct mode can
// still cross. ClipCursor is system-wide and other programs (or Windows) may change or reset
// it, so the viewer re-applies it only when nobody else holds a clip.
public static class SvClip {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, uint i, ref DISPLAY_DEVICE d, uint flags);
    [DllImport("user32.dll")] static extern bool ClipCursor(ref SvRect r);
    [DllImport("user32.dll")] static extern bool ClipCursor(IntPtr r);
    [DllImport("user32.dll")] static extern bool GetClipCursor(out SvRect r);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);

    // Adapter description of a screen (for example "Parsec Virtual Display Adapter").
    public static string AdapterOf(string screenDevice) {
        DISPLAY_DEVICE d = new DISPLAY_DEVICE(); d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        for (uint i = 0; EnumDisplayDevices(null, i, ref d, 0); i++) {
            if (string.Equals(d.DeviceName, screenDevice, StringComparison.OrdinalIgnoreCase)) return d.DeviceString;
            d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        }
        return "";
    }
    public static bool IsVirtual(string screenDevice) {
        string a = AdapterOf(screenDevice);
        return a.IndexOf("Parsec", StringComparison.OrdinalIgnoreCase) >= 0 || a.IndexOf("Virtual Display", StringComparison.OrdinalIgnoreCase) >= 0;
    }
    // Physical buttons (GetAsyncKeyState reads the device, so swapped buttons do not matter here).
    public static bool AnyButtonDown() {
        return (GetAsyncKeyState(0x01) & 0x8000) != 0 || (GetAsyncKeyState(0x02) & 0x8000) != 0 || (GetAsyncKeyState(0x04) & 0x8000) != 0;
    }
    public static Rectangle Current() { SvRect r; GetClipCursor(out r); return Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom); }
    public static void Set(Rectangle b) { SvRect r; r.Left = b.Left; r.Top = b.Top; r.Right = b.Right; r.Bottom = b.Bottom; ClipCursor(ref r); }
    public static void Release() { ClipCursor(IntPtr.Zero); }
}

// Hidden window that receives raw mouse motion (still reported when Windows holds the cursor
// at the edge of the desktop) and the global exit hotkey (Ctrl+Alt+Q).
public class SvInput : NativeWindow {
    [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICE { public ushort UsagePage; public ushort Usage; public uint Flags; public IntPtr Target; }
    [DllImport("user32.dll")] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] d, uint n, uint size);
    [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr h, uint cmd, IntPtr data, ref uint size, uint header);
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    const int WM_INPUT = 0x00FF, WM_HOTKEY = 0x0312, HOTKEY_ID = 0x5356;
    int dx, dy; bool hot;
    public bool RawOk, HotkeyOk;
    public SvInput() {
        CreateHandle(new CreateParams());
        RAWINPUTDEVICE[] d = new RAWINPUTDEVICE[1];
        d[0].UsagePage = 1; d[0].Usage = 2; d[0].Flags = 0x100; d[0].Target = Handle;   // mouse, RIDEV_INPUTSINK
        RawOk = RegisterRawInputDevices(d, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)));
        HotkeyOk = RegisterHotKey(Handle, HOTKEY_ID, 0x0002 | 0x0001 | 0x4000, 0x51);       // Ctrl+Alt, no repeat, Q
    }
    public int TakeX() { int v = dx; dx = 0; return v; }
    public int TakeY() { int v = dy; dy = 0; return v; }
    public bool TakeHotkey() { bool v = hot; hot = false; return v; }
    public void Close() { UnregisterHotKey(Handle, HOTKEY_ID); DestroyHandle(); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_INPUT) {
            uint header = (uint)(8 + 2 * IntPtr.Size), size = 0;
            GetRawInputData(m.LParam, 0x10000003, IntPtr.Zero, ref size, header);
            if (size > 0) {
                IntPtr buf = Marshal.AllocHGlobal((int)size);
                try {
                    if (GetRawInputData(m.LParam, 0x10000003, buf, ref size, header) == size && Marshal.ReadInt32(buf) == 0) {
                        int off = (int)header;
                        bool absolute = (Marshal.ReadInt16(buf, off) & 1) != 0;   // MOUSE_MOVE_ABSOLUTE (tablets, remote desktop)
                        if (!absolute) { dx += Marshal.ReadInt32(buf, off + 12); dy += Marshal.ReadInt32(buf, off + 16); }
                    }
                } finally { Marshal.FreeHGlobal(buf); }
            }
        } else if (m.Msg == WM_HOTKEY && (int)m.WParam == HOTKEY_ID) {
            hot = true;
        }
        base.WndProc(ref m);
    }
}
"@

# Physical pixels on every monitor. With mixed scaling (for example 125% main screen and a
# 100% virtual screen) a system-DPI-aware process sees the second screen at the wrong size,
# so per-monitor awareness is required for the cursor to land where the image shows.
function Set-PerMonitorDpi {
    try { if ([SvNative]::SetProcessDpiAwarenessContext([IntPtr](-4))) { return 'per-monitor-v2' } } catch {}
    try { if ([SvNative]::SetProcessDpiAwareness(2) -eq 0) { return 'per-monitor' } } catch {}
    try { if ([SvNative]::SetProcessDPIAware()) { return 'system' } } catch {}
    return 'unaware'
}

# Map a point inside a box that shows the screen letterboxed (Zoom) to screen coordinates.
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

# Inverse of Convert-ViewToScreen: a screen point to box coordinates.
function Convert-ScreenToView([double]$sx, [double]$sy, [double]$boxW, [double]$boxH, $bounds) {
    $scale = [Math]::Min($boxW / $bounds.Width, $boxH / $bounds.Height)
    $offX = ($boxW - $bounds.Width * $scale) / 2
    $offY = ($boxH - $bounds.Height * $scale) / 2
    return [pscustomobject]@{ X = $offX + ($sx - $bounds.X) * $scale; Y = $offY + ($sy - $bounds.Y) * $scale; Scale = $scale }
}

# Rectangle inside a box where the screen image goes (same math as Convert-ViewToScreen).
function Get-LetterBox([double]$boxW, [double]$boxH, $bounds) {
    $scale = [Math]::Min($boxW / $bounds.Width, $boxH / $bounds.Height)
    if ($scale -le 0) { $scale = 0.01 }
    $w = [int][Math]::Round($bounds.Width * $scale)
    $h = [int][Math]::Round($bounds.Height * $scale)
    return [pscustomobject]@{ X = [int][Math]::Floor(($boxW - $w) / 2); Y = [int][Math]::Floor(($boxH - $h) / 2); W = $w; H = $h; Scale = $scale }
}

# Area the cursor is kept in while a virtual screen exists: the bounding box of the screens that
# are not virtual. $null (no lock) when there is no virtual screen, or when that box would also
# cover a virtual screen (a rectangle cannot express the layout).
function Get-HomeRect($screens) {
    $virtual = @($screens | Where-Object { $_.Virtual })
    $real = @($screens | Where-Object { -not $_.Virtual })
    if ($virtual.Count -eq 0 -or $real.Count -eq 0) { return $null }
    $l = ($real | ForEach-Object { $_.Bounds.X } | Measure-Object -Minimum).Minimum
    $t = ($real | ForEach-Object { $_.Bounds.Y } | Measure-Object -Minimum).Minimum
    $r = ($real | ForEach-Object { $_.Bounds.X + $_.Bounds.Width } | Measure-Object -Maximum).Maximum
    $b = ($real | ForEach-Object { $_.Bounds.Y + $_.Bounds.Height } | Measure-Object -Maximum).Maximum
    foreach ($v in $virtual) {
        $vb = $v.Bounds
        if ($vb.X -lt $r -and $vb.X + $vb.Width -gt $l -and $vb.Y -lt $b -and $vb.Y + $vb.Height -gt $t) { return $null }
    }
    return [pscustomobject]@{ X = [int]$l; Y = [int]$t; Width = [int]($r - $l); Height = [int]($b - $t) }
}

# Where the floating toolbar goes in small mode: centered above the window, below it when there
# is no room above, and inside its top edge when there is no room on either side.
function Get-ToolbarPlacement($win, [int]$tbW, [int]$tbH, $area, [int]$gap) {
    $x = [int]($win.X + ($win.Width - $tbW) / 2)
    $x = [Math]::Max($area.X, [Math]::Min($area.X + $area.Width - $tbW, $x))
    $above = $win.Y - $tbH - $gap
    if ($above -ge $area.Y) { return [pscustomobject]@{ X = $x; Y = $above; Side = 'above' } }
    $below = $win.Y + $win.Height + $gap
    if ($below + $tbH -le $area.Y + $area.Height) { return [pscustomobject]@{ X = $x; Y = $below; Side = 'below' } }
    return [pscustomobject]@{ X = $x; Y = $win.Y + $gap; Side = 'inside' }
}

# How hard the hand pushes past an edge where Windows holds the cursor still (the outer edges
# of the desktop). $x,$y is the cursor on screen $bounds; $rawX,$rawY is the raw mouse motion
# since the last tick; $push is the previous result. Moving back inward resets the push; a
# tick with no motion keeps it. OverX/OverY is -1 or 1 once the push passes $threshold.
function Get-EdgePush([int]$x, [int]$y, $bounds, [int]$rawX, [int]$rawY, $push, [int]$threshold = 6) {
    $nx = 0; $ny = 0
    if ($x -le $bounds.X) {
        if ($rawX -lt 0) { $nx = [Math]::Min(0, $push.X) + $rawX } elseif ($rawX -eq 0) { $nx = [Math]::Min(0, $push.X) }
    } elseif ($x -ge $bounds.X + $bounds.Width - 1) {
        if ($rawX -gt 0) { $nx = [Math]::Max(0, $push.X) + $rawX } elseif ($rawX -eq 0) { $nx = [Math]::Max(0, $push.X) }
    }
    if ($y -le $bounds.Y) {
        if ($rawY -lt 0) { $ny = [Math]::Min(0, $push.Y) + $rawY } elseif ($rawY -eq 0) { $ny = [Math]::Min(0, $push.Y) }
    } elseif ($y -ge $bounds.Y + $bounds.Height - 1) {
        if ($rawY -gt 0) { $ny = [Math]::Max(0, $push.Y) + $rawY } elseif ($rawY -eq 0) { $ny = [Math]::Max(0, $push.Y) }
    }
    $ox = if ($nx -le -$threshold) { -1 } elseif ($nx -ge $threshold) { 1 } else { 0 }
    $oy = if ($ny -le -$threshold) { -1 } elseif ($ny -ge $threshold) { 1 } else { 0 }
    return [pscustomobject]@{ X = $nx; Y = $ny; OverX = $ox; OverY = $oy }
}

if ($SelfTest) {
    $fail = 0; $total = 0
    function Check([bool]$ok, [string]$what) { $script:total++; if (-not $ok) { $script:fail++; Write-Output "FAIL $what" } }
    $b = [pscustomobject]@{ X = 1920; Y = 0; Width = 1920; Height = 1080 }
    $cases = @(
        @{ In = @(320, 180, 640, 360); Want = @(2880, 540) },   # center, exact fit
        @{ In = @(0, 0, 640, 360);     Want = @(1920, 0) },     # top-left corner
        @{ In = @(320, 240, 640, 480); Want = @(2880, 540) },   # center with letterbox bars
        @{ In = @(320, 10, 640, 480);  Want = $null },          # on the top bar
        @{ In = @(-5, 100, 640, 360);  Want = $null }           # outside the box
    )
    foreach ($c in $cases) {
        $r = Convert-ViewToScreen $c.In[0] $c.In[1] $c.In[2] $c.In[3] $b
        $ok = if ($null -eq $c.Want) { $null -eq $r } else { $r -and $r.X -eq $c.Want[0] -and $r.Y -eq $c.Want[1] }
        Check $ok "view-to-screen in=$($c.In -join ',') got=$($r.X),$($r.Y)"
    }
    $inv = Convert-ScreenToView 2880 540 640 480 $b
    Check ([Math]::Abs($inv.X - 320) -le 0.01 -and [Math]::Abs($inv.Y - 240) -le 0.01) "inverse got=$($inv.X),$($inv.Y)"
    # Letterbox: a 16:9 screen in a 4:3 box gets bars on top and bottom only.
    $lb = Get-LetterBox 640 480 $b
    Check ($lb.X -eq 0 -and $lb.Y -eq 60 -and $lb.W -eq 640 -and $lb.H -eq 360) "letterbox 4:3 got=$($lb.X),$($lb.Y),$($lb.W),$($lb.H)"
    $lb = Get-LetterBox 1920 1080 ([pscustomobject]@{ X = 2400; Y = 0; Width = 2400; Height = 1350 })
    Check ($lb.X -eq 0 -and $lb.Y -eq 0 -and $lb.W -eq 1920 -and $lb.H -eq 1080 -and [Math]::Abs($lb.Scale - 0.8) -lt 0.0001) "letterbox full got=$($lb.X),$($lb.Y),$($lb.W),$($lb.H),$($lb.Scale)"
    # Toolbar: above the window, below when the window touches the top, inside when it fills the area.
    $area = [pscustomobject]@{ X = 0; Y = 0; Width = 1920; Height = 1040 }
    $p = Get-ToolbarPlacement ([pscustomobject]@{ X = 1200; Y = 600; Width = 600; Height = 380 }) 300 40 $area 4
    Check ($p.Side -eq 'above' -and $p.X -eq 1350 -and $p.Y -eq 556) "toolbar above got=$($p.Side),$($p.X),$($p.Y)"
    $p = Get-ToolbarPlacement ([pscustomobject]@{ X = 1700; Y = 10; Width = 600; Height = 380 }) 300 40 $area 4
    Check ($p.Side -eq 'below' -and $p.X -eq 1620 -and $p.Y -eq 394) "toolbar below, clamped got=$($p.Side),$($p.X),$($p.Y)"
    $p = Get-ToolbarPlacement ([pscustomobject]@{ X = 0; Y = 0; Width = 1920; Height = 1040 }) 300 40 $area 4
    Check ($p.Side -eq 'inside' -and $p.Y -eq 4) "toolbar inside got=$($p.Side),$($p.X),$($p.Y)"
    # Edge push: Windows stops the cursor at the outer edges of the desktop, so only the raw
    # mouse motion shows that the hand keeps pushing outward.
    $zero = [pscustomobject]@{ X = 0; Y = 0 }
    $pushCases = @(
        @{ At = @(3839, 500); Raw = @(4, 0);   Push = $zero;                                Want = @(4, 0, 0, 0) },   # right edge, below threshold
        @{ At = @(3839, 500); Raw = @(3, 0);   Push = [pscustomobject]@{ X = 4; Y = 0 };    Want = @(7, 0, 1, 0) },   # right edge, accumulates past it
        @{ At = @(2500, 0);   Raw = @(0, -9);  Push = $zero;                                Want = @(0, -9, 0, -1) }, # top edge, one strong push
        @{ At = @(2500, 1079); Raw = @(0, 0);  Push = [pscustomobject]@{ X = 0; Y = 5 };    Want = @(0, 5, 0, 0) },   # bottom edge, still: keeps push
        @{ At = @(3839, 500); Raw = @(-2, 0);  Push = [pscustomobject]@{ X = 5; Y = 0 };    Want = @(0, 0, 0, 0) },   # moving back inward resets
        @{ At = @(2500, 500); Raw = @(50, 50); Push = [pscustomobject]@{ X = 5; Y = 5 };    Want = @(0, 0, 0, 0) }    # not on an edge: no push
    )
    foreach ($c in $pushCases) {
        $r = Get-EdgePush $c.At[0] $c.At[1] $b $c.Raw[0] $c.Raw[1] $c.Push
        $got = @($r.X, $r.Y, $r.OverX, $r.OverY)
        Check (($got -join ',') -eq ($c.Want -join ',')) "push at=$($c.At -join ',') raw=$($c.Raw -join ',') got=$($got -join ',')"
    }
    # Cursor lock area: real screens only, never a box that also covers a virtual screen.
    function Scr($x, $y, $w, $h, $v) { [pscustomobject]@{ Bounds = [pscustomobject]@{ X = $x; Y = $y; Width = $w; Height = $h }; Virtual = $v } }
    $hr = Get-HomeRect @((Scr 0 0 1920 1080 $false), (Scr 1920 0 1920 1080 $true))
    Check ($hr -and $hr.X -eq 0 -and $hr.Width -eq 1920 -and $hr.Height -eq 1080) "home: main + virtual got=$($hr.X),$($hr.Y),$($hr.Width),$($hr.Height)"
    $hr = Get-HomeRect @((Scr 0 0 1920 1080 $false), (Scr -1280 0 1280 1024 $false), (Scr 1920 0 1920 1080 $true))
    Check ($hr -and $hr.X -eq -1280 -and $hr.Width -eq 3200 -and $hr.Height -eq 1080) "home: two real + virtual got=$($hr.X),$($hr.Width),$($hr.Height)"
    $hr = Get-HomeRect @((Scr 0 0 1920 1080 $false), (Scr 1920 0 1920 1080 $true), (Scr 3840 0 1920 1080 $false))
    Check ($null -eq $hr) "home: virtual between real screens -> no lock"
    $hr = Get-HomeRect @((Scr 0 0 1920 1080 $false), (Scr 1920 0 1920 1080 $false))
    Check ($null -eq $hr) "home: no virtual screen -> no lock"
    Write-Output "selftest: $($total - $fail)/$total passed"
    exit $fail
}

$script:dpiMode = Set-PerMonitorDpi

# Hide only the console window, so the viewer form itself stays visible.
if (-not $Smoke) { [SvNative]::ShowWindow([SvNative]::GetConsoleWindow(), 0) | Out-Null }

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
    if ($Smoke) { [Console]::WriteLine($text) }
}

# Per-monitor awareness turns off automatic scaling: size everything by the main screen's scale.
$probe = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$k = [Math]::Max(1.0, $probe.DpiX / 96.0)
$probe.Dispose()
function Px([double]$v) { [int][Math]::Round($v * $k) }

$cWindow = [Drawing.Color]::FromArgb(24, 24, 26)
$cBar    = [Drawing.Color]::FromArgb(36, 36, 40)
$cHover  = [Drawing.Color]::FromArgb(64, 64, 70)
$cText   = [Drawing.Color]::FromArgb(232, 232, 232)
$cDim    = [Drawing.Color]::FromArgb(150, 150, 156)
$cOn     = [Drawing.Color]::FromArgb(96, 170, 255)
$cClose  = [Drawing.Color]::FromArgb(196, 43, 28)
$glyphFont = New-Object Drawing.Font('Segoe MDL2 Assets', [single](Px 12), [Drawing.GraphicsUnit]::Pixel)
$textFont  = New-Object Drawing.Font('Segoe UI', [single](Px 12), [Drawing.GraphicsUnit]::Pixel)

# --- state ----------------------------------------------------------------------------------
$script:remote = $false
$script:needLeave = $false
$script:px = 0.0
$script:py = 0.0
$script:lastX = 0
$script:lastY = 0
$script:bmp = $null
$script:push = [pscustomobject]@{ X = 0; Y = 0 }
$script:full = $false
$script:normalBounds = $null
$script:onTop = $true
$script:showPointer = $true
$script:userHid = $false
$script:muted = @()
$script:mag = [IntPtr]::Zero
$script:magOk = $false
$script:pic = $null
$script:magBounds = $null
$script:clock = [Diagnostics.Stopwatch]::StartNew()
$script:lastFrameMs = -1000
$script:tbLastNear = 0
$script:lockOn = $true
$script:clipMine = $false
$script:homeRect = $null
$script:homeCheckMs = -10000

# --- main window ----------------------------------------------------------------------------
$form = New-Object SvForm
$form.Text = "Test screen (live, touch)"
$form.FormBorderStyle = 'None'
$form.TopMost = $true
$form.ShowInTaskbar = $true
$form.StartPosition = 'Manual'
$form.BackColor = $cWindow
$form.Grip = Px 5
$form.Padding = New-Object Windows.Forms.Padding($form.Grip)
$form.MinimumSize = New-Object Drawing.Size((Px 240), (Px 150))
$form.Size = New-Object Drawing.Size((Px 640), (Px 380))
$primary = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object Drawing.Point(($primary.Right - $form.Width - (Px 20)), ($primary.Bottom - $form.Height - (Px 20)))
if ($Smoke) {
    $sb = $screen.Bounds
    $form.Location = New-Object Drawing.Point(($sb.Right - $form.Width - (Px 40)), ($sb.Bottom - $form.Height - (Px 60)))
}
Write-ViewerLog "start dpi=$($script:dpiMode) scale=$k second=$($screen.Bounds)"

# Thin strip on top: drag it to move the window; hover it to bring back a hidden toolbar.
$grip = New-Object Windows.Forms.Panel
$grip.Dock = 'Top'
$grip.Height = Px 10
$grip.BackColor = $cBar
$grip.Cursor = [Windows.Forms.Cursors]::SizeAll
$grip.Add_Paint({
    param($sender, $e)
    $w = Px 36; $h = [Math]::Max(2, (Px 3))
    $x = [int](($grip.Width - $w) / 2); $y = [int](($grip.Height - $h) / 2)
    $brush = New-Object Drawing.SolidBrush($cDim)
    $e.Graphics.FillRectangle($brush, $x, $y, $w, $h)
    $brush.Dispose()
})
$grip.Add_MouseDown({ param($sender, $e) if ($e.Button -eq 'Left') { [SvForm]::DragMove($form) } })
$grip.Add_MouseEnter({ Show-Toolbar })

$view = New-Object Windows.Forms.Panel
$view.Dock = 'Fill'
$view.BackColor = [Drawing.Color]::Black
$form.Controls.Add($view)
$form.Controls.Add($grip)

# --- floating toolbar -----------------------------------------------------------------------
$tb = New-Object SvForm
$tb.Resizable = $false
$tb.NoActivate = $true
$tb.FormBorderStyle = 'None'
$tb.ShowInTaskbar = $false
$tb.StartPosition = 'Manual'
$tb.BackColor = $cBar
$tip = New-Object Windows.Forms.ToolTip

$flow = New-Object Windows.Forms.FlowLayoutPanel
$flow.WrapContents = $false
$flow.AutoSize = $true
$flow.AutoSizeMode = 'GrowAndShrink'
$flow.Padding = New-Object Windows.Forms.Padding((Px 8), (Px 3), (Px 4), (Px 3))
$flow.BackColor = $cBar
$tb.Controls.Add($flow)

$title = New-Object Windows.Forms.Label
$title.Text = "Second screen"
$title.Font = $textFont
$title.ForeColor = $cDim
$title.AutoSize = $false
$title.Size = New-Object Drawing.Size((Px 96), (Px 28))
$title.TextAlign = 'MiddleLeft'
$title.Margin = New-Object Windows.Forms.Padding(0, 0, (Px 4), 0)
$title.Cursor = [Windows.Forms.Cursors]::SizeAll
$title.Add_MouseDown({ param($sender, $e) if ($e.Button -eq 'Left' -and -not $script:full) { [SvForm]::DragMove($form) } })
$flow.Controls.Add($title)

function New-ToolButton([string]$tipText, [scriptblock]$onClick, [Drawing.Color]$hoverColor) {
    $b = New-Object Windows.Forms.Label
    $b.AutoSize = $false
    $b.Size = New-Object Drawing.Size((Px 32), (Px 28))
    $b.TextAlign = 'MiddleCenter'
    $b.Font = $glyphFont
    $b.ForeColor = $cText
    $b.BackColor = $cBar
    $b.Margin = New-Object Windows.Forms.Padding((Px 1), 0, (Px 1), 0)
    $b.Cursor = [Windows.Forms.Cursors]::Hand
    $b.Tag = $hoverColor
    $b.Add_MouseEnter({ param($sender, $e) $sender.BackColor = $sender.Tag })
    $b.Add_MouseLeave({ param($sender, $e) $sender.BackColor = $cBar })
    $b.Add_Click($onClick)
    $tip.SetToolTip($b, $tipText)
    $flow.Controls.Add($b)
    return $b
}

$btnPin     = New-ToolButton "Always on top" { $script:onTop = -not $script:onTop; $form.TopMost = $script:onTop; Update-Glyphs } $cHover
$btnPointer = New-ToolButton "Show the pointer in the image" { Switch-Pointer } $cHover
$btnMute    = New-ToolButton "Mute the apps on the second screen" { Switch-Mute } $cHover
$btnLock    = New-ToolButton "Keep the mouse on the main screen" { Switch-Lock } $cHover
$btnFull    = New-ToolButton "Full screen" { Set-Fullscreen (-not $script:full) } $cHover
$btnHide    = New-ToolButton "Hide this bar (hover the top edge to bring it back)" { Switch-HideBar } $cHover
$btnMin     = New-ToolButton "Minimize" { $form.WindowState = 'Minimized' } $cHover
$btnClose   = New-ToolButton "Close" { $form.Close() } $cClose

function Set-Rounded($f, [int]$r) {
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $w = $f.Width; $h = $f.Height; $d = 2 * $r
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($w - $d, 0, $d, $d, 270, 90)
    $path.AddArc($w - $d, $h - $d, $d, $d, 0, 90)
    $path.AddArc(0, $h - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $f.Region = New-Object Drawing.Region($path)
}

function Update-ToolbarSize {
    $btnPin.Visible = -not $script:full
    $title.Visible = -not $script:full
    $flow.PerformLayout()
    $tb.ClientSize = $flow.PreferredSize
    Set-Rounded $tb (Px 8)
}

function Update-Glyphs {
    $btnPin.Text = if ($script:onTop) { [string][char]0xE718 } else { [string][char]0xE77A }
    $btnPin.ForeColor = if ($script:onTop) { $cOn } else { $cText }
    $tip.SetToolTip($btnPin, $(if ($script:onTop) { "Always on top: on" } else { "Always on top: off" }))
    $btnPointer.Text = [string][char]0xE7C9
    $btnPointer.ForeColor = if ($script:showPointer) { $cOn } else { $cText }
    $tip.SetToolTip($btnPointer, $(if ($script:showPointer) { "Pointer shown in the image (turn off when an app draws its own)" } else { "Pointer hidden in the image" }))
    $btnMute.Text = if ($script:muted.Count) { [string][char]0xE74F } else { [string][char]0xE767 }
    $btnMute.ForeColor = if ($script:muted.Count) { $cOn } else { $cText }
    $btnLock.Text = if ($script:lockOn) { [string][char]0xE72E } else { [string][char]0xE785 }
    $btnLock.ForeColor = if ($script:lockOn -and $script:homeRect) { $cOn } else { $cText }
    $tip.SetToolTip($btnLock, $(if (-not $script:homeRect) { "Mouse lock: not needed or not possible with this screen layout" } elseif ($script:lockOn) { "Mouse kept on the main screen (drag a window or use the image to cross): on" } else { "Mouse kept on the main screen: off" }))
    $btnFull.Text = if ($script:full) { [string][char]0xE73F } else { [string][char]0xE740 }
    $tip.SetToolTip($btnFull, $(if ($script:full) { "Back to the small window" } else { "Full screen" }))
    $btnHide.Text = if ($script:userHid -and -not $script:full) { [string][char]0xE70D } else { [string][char]0xE70E }
    $tip.SetToolTip($btnHide, $(if ($script:userHid -and -not $script:full) { "Keep this bar visible" } else { "Hide this bar (hover the top edge to bring it back)" }))
    $btnMin.Text = [string][char]0xE921
    $btnClose.Text = [string][char]0xE8BB
}

function Update-ToolbarPlacement {
    if ($script:full) {
        $sb = [Windows.Forms.Screen]::FromControl($form).Bounds
        $tb.Location = New-Object Drawing.Point(([int]($sb.X + ($sb.Width - $tb.Width) / 2)), ($sb.Y + (Px 8)))
    } else {
        $area = [Windows.Forms.Screen]::FromControl($form).WorkingArea
        $p = Get-ToolbarPlacement $form.Bounds $tb.Width $tb.Height $area (Px 4)
        $tb.Location = New-Object Drawing.Point($p.X, $p.Y)
    }
}

function Show-Toolbar {
    if ($form.WindowState -eq 'Minimized') { return }
    Update-ToolbarPlacement
    if (-not $tb.Visible) { $tb.Show($form) }
    $script:tbLastNear = $script:clock.ElapsedMilliseconds
}

function Switch-HideBar {
    if ($script:full) { $tb.Hide(); return }
    $script:userHid = -not $script:userHid
    Update-Glyphs
    if ($script:userHid) { $tb.Hide() } else { Show-Toolbar }
}

function Set-Fullscreen([bool]$on) {
    if ($on -eq $script:full) { return }
    if ($on) {
        $script:normalBounds = $form.Bounds
        $sb = [Windows.Forms.Screen]::FromControl($form).Bounds
        $script:full = $true
        $form.Resizable = $false
        $grip.Visible = $false
        $form.Padding = New-Object Windows.Forms.Padding(0)
        $form.TopMost = $false
        $form.Bounds = $sb
    } else {
        $script:full = $false
        $form.Resizable = $true
        $grip.Visible = $true
        $form.Padding = New-Object Windows.Forms.Padding($form.Grip)
        $form.Bounds = $script:normalBounds
        $form.TopMost = $script:onTop
    }
    Write-ViewerLog "fullscreen=$on"
    Update-ToolbarSize
    Update-Glyphs
    Update-MagLayout
    if ($script:full -or -not $script:userHid) { Show-Toolbar } else { $tb.Hide() }
}

# --- cursor lock ----------------------------------------------------------------------------
function Update-HomeRect {
    $list = foreach ($sc in [Windows.Forms.Screen]::AllScreens) {
        [pscustomobject]@{ Bounds = $sc.Bounds; Virtual = [SvClip]::IsVirtual($sc.DeviceName) }
    }
    $new = Get-HomeRect $list
    if ("$($script:homeRect)" -ne "$new") {
        Release-CursorLock   # still compares against the old area
        $script:homeRect = $new
        Write-ViewerLog "mouse lock area=$(if ($new) { "$($new.X),$($new.Y),$($new.Width)x$($new.Height)" } else { 'none' })"
        Update-Glyphs
    }
}

# A clip outlives the process that set it (checked on Windows 10), so a crashed viewer would leave
# the mouse locked. A hidden watchdog process waits for the viewer to exit and then releases the
# clip if it is still the one recorded in the state file; a normal close deletes the file first.
$script:clipFile = Join-Path $env:TEMP "modo-equipo-viewer-clip-$PID.txt"
function Start-ClipWatchdog {
    $code = @"
Add-Type 'using System; using System.Runtime.InteropServices; public static class W { [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; } [DllImport("user32.dll")] public static extern bool GetClipCursor(out R r); [DllImport("user32.dll")] public static extern bool ClipCursor(IntPtr r); [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v); }'
[W]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
try { Wait-Process -Id $PID -ErrorAction Stop } catch {}
`$f = '$($script:clipFile)'
if (Test-Path `$f) {
    `$want = (Get-Content `$f -Raw).Trim()
    `$r = New-Object W+R; [void][W]::GetClipCursor([ref]`$r)
    if ("`$(`$r.L),`$(`$r.T),`$(`$r.Rt),`$(`$r.B)" -eq `$want) { [void][W]::ClipCursor([IntPtr]::Zero) }
    Remove-Item `$f -ErrorAction SilentlyContinue
}
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    try {
        Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $enc" -WindowStyle Hidden | Out-Null
        Write-ViewerLog "mouse lock watchdog started"
    } catch { Write-ViewerLog "mouse lock watchdog failed: $($_.Exception.Message)" }
}

function Save-ClipState {
    $h = $script:homeRect
    try {
        if ($script:clipMine -and $h) { Set-Content -Path $script:clipFile -Value "$($h.X),$($h.Y),$($h.X + $h.Width),$($h.Y + $h.Height)" -ErrorAction Stop }
        elseif (Test-Path $script:clipFile) { Remove-Item $script:clipFile -ErrorAction Stop }
    } catch {}
}

function Test-ClipIsHome($c) {
    $h = $script:homeRect
    return [bool]($h -and $c.X -eq $h.X -and $c.Y -eq $h.Y -and $c.Width -eq $h.Width -and $c.Height -eq $h.Height)
}

function Release-CursorLock {
    if (-not $script:clipMine) { return }
    # Only undo our own clip; a clip another program set later is left alone.
    if (Test-ClipIsHome ([SvClip]::Current())) { [SvClip]::Release() }
    $script:clipMine = $false
    Save-ClipState
}

# Called every tick: lock while idle, free while a button is held or in direct mode.
function Update-CursorLock([long]$now) {
    if (($now - $script:homeCheckMs) -ge 1000) { $script:homeCheckMs = $now; Update-HomeRect }
    $h = $script:homeRect
    $want = $script:lockOn -and $h -and -not $script:remote -and -not $Smoke -and -not [SvClip]::AnyButtonDown()
    if (-not $want) { Release-CursorLock; return }
    $c = [SvClip]::Current()
    if (Test-ClipIsHome $c) { if (-not $script:clipMine) { $script:clipMine = $true; Save-ClipState }; return }
    # Re-apply only when nobody holds a clip (the clip is the whole desktop); never fight a
    # program that confines the cursor itself (for example a game on the main screen).
    if ($c -eq [Windows.Forms.SystemInformation]::VirtualScreen) {
        [SvClip]::Set((New-Object Drawing.Rectangle($h.X, $h.Y, $h.Width, $h.Height)))
        if (-not $script:clipMine) { $script:clipMine = $true; Save-ClipState }
    }
}

function Switch-Lock {
    $script:lockOn = -not $script:lockOn
    if (-not $script:lockOn) { Release-CursorLock }
    Write-ViewerLog "mouse lock=$($script:lockOn)"
    Update-Glyphs
}

function Switch-Pointer {
    $script:showPointer = -not $script:showPointer
    if ($script:magOk) { [SvMag]::SetCursorVisible($script:mag, $script:showPointer) }
    Update-Glyphs
}

function Switch-Mute {
    try {
        if ($script:muted.Count) {
            [SvAudio]::SetMute([string[]]$script:muted, $false) | Out-Null
            Write-ViewerLog "unmuted $($script:muted -join ',')"
            $script:muted = @()
        } else {
            $s = Get-SecondScreen
            if (-not $s) { return }
            $b = $s.Bounds
            $names = [SvAudio]::ProcessNamesOn($b.X, $b.Y, $b.Width, $b.Height, $PID)
            $n = [SvAudio]::SetMute($names, $true)
            Write-ViewerLog "muted sessions=$n apps=$($names -join ',')"
            if ($n -gt 0) { $script:muted = @($names) }
            else { $tip.Show("No sound found from the apps on the second screen", $btnMute, 0, $btnMute.Height, 2500) }
        }
    } catch { Write-ViewerLog "mute failed: $($_.Exception.Message)" }
    Update-Glyphs
}

# --- picture: Magnification API, or GDI copy as fallback ------------------------------------
function Initialize-View {
    $script:magOk = [SvMag]::Init()
    if ($script:magOk) {
        $script:mag = [SvMag]::Create($view.Handle, $script:showPointer)
        if ($script:mag -eq [IntPtr]::Zero) { $script:magOk = $false; [SvMag]::Shutdown() }
    }
    if (-not $script:magOk) {
        $script:pic = New-Object Windows.Forms.PictureBox
        $script:pic.Dock = 'Fill'
        $script:pic.SizeMode = 'Zoom'
        $view.Controls.Add($script:pic)
    }
    Write-ViewerLog "renderer=$(if ($script:magOk) { 'magnification' } else { 'gdi' })"
    Update-MagLayout
}

function Update-MagLayout {
    if (-not $script:magOk) { return }
    $s = Get-SecondScreen
    if (-not $s) { return }
    $lb = Get-LetterBox $view.ClientSize.Width $view.ClientSize.Height $s.Bounds
    [SvMag]::Place($script:mag, $lb.X, $lb.Y, $lb.W, $lb.H, [single]$lb.Scale) | Out-Null
    $script:magBounds = $s.Bounds
}

function Update-GdiFrame($b) {
    if (-not $script:bmp -or $script:bmp.Width -ne $b.Width -or $script:bmp.Height -ne $b.Height) {
        $script:bmp = New-Object Drawing.Bitmap($b.Width, $b.Height, [Drawing.Imaging.PixelFormat]::Format32bppPArgb)
        $script:pic.Image = $script:bmp
    }
    $g = [Drawing.Graphics]::FromImage($script:bmp)
    $g.CopyFromScreen($b.X, $b.Y, 0, 0, $script:bmp.Size)
    # Screen copies do not include the cursor: draw a marker where it is on that screen.
    $c = [Windows.Forms.Cursor]::Position
    if ($script:showPointer -and $b.Contains($c)) {
        $r = [Math]::Max(6, [int]($b.Width / 160))
        $g.FillEllipse([Drawing.Brushes]::Red, $c.X - $b.X - $r, $c.Y - $b.Y - $r, 2 * $r, 2 * $r)
    }
    $g.Dispose()
    $script:pic.Invalidate()
}

$view.Add_Resize({ Update-MagLayout })
$form.Add_LocationChanged({ if ($tb.Visible) { Update-ToolbarPlacement } })
$form.Add_SizeChanged({
    if ($form.WindowState -eq 'Minimized') { return }
    if ($tb.Visible) { Update-ToolbarPlacement }
    elseif (-not $script:full -and -not $script:userHid) { Show-Toolbar }
})

# --- direct mode ----------------------------------------------------------------------------
# While the pointer is over the image, the real cursor lives on the second screen and moves
# with the hand, scaled so the cursor on the image follows the pointer 1:1. Clicks, double
# clicks, drags and the wheel are then ordinary native input. Moving past the image edge
# hands the cursor back to the viewer's side.
$script:input = New-Object SvInput
Write-ViewerLog "raw input=$($script:input.RawOk) hotkey Ctrl+Alt+Q=$($script:input.HotkeyOk)"
$hintText = if ($script:input.HotkeyOk) { "Move over the image to use the second screen; push past any edge or press Ctrl+Alt+Q to come back" } else { "Move over the image to use the second screen; push past any edge to come back" }
$tip.SetToolTip($title, $hintText)

function Test-OverImage($cur) {
    $pt = New-Object SvPt; $pt.X = $cur.X; $pt.Y = $cur.Y
    $h = [SvNative]::WindowFromPoint($pt)
    if ($h -eq $view.Handle) { return $true }
    if ($script:magOk -and $h -eq $script:mag) { return $true }
    if ($script:pic -and $h -eq $script:pic.Handle) { return $true }
    return $false
}

function Enter-Remote($cur) {
    $p = $view.PointToClient($cur)
    $s = Get-SecondScreen
    if (-not $s) { return }
    $t = Convert-ViewToScreen $p.X $p.Y $view.ClientSize.Width $view.ClientSize.Height $s.Bounds
    if (-not $t) { return }
    $script:px = [double]$t.X; $script:py = [double]$t.Y
    $script:lastX = $t.X; $script:lastY = $t.Y
    Release-CursorLock   # the clip would hold the cursor on the main screen
    [SvNative]::SetCursorPos($t.X, $t.Y) | Out-Null
    $script:push = [pscustomobject]@{ X = 0; Y = 0 }
    $script:remote = $true
    Write-ViewerLog "enter remote at $($t.X),$($t.Y)"
}

function Exit-Remote($b, $overX, $overY) {
    $script:remote = $false
    $script:needLeave = $true
    if ($script:full) {
        # The image covers the whole screen: come back onto the toolbar.
        Show-Toolbar
        $c = $tb.PointToScreen((New-Object Drawing.Point([int]($tb.ClientSize.Width / 2), [int]($tb.ClientSize.Height / 2))))
        [SvNative]::SetCursorPos($c.X, $c.Y) | Out-Null
    } else {
        $v = Convert-ScreenToView ([Math]::Max($b.Left, [Math]::Min($b.Right - 1, $script:px))) ([Math]::Max($b.Top, [Math]::Min($b.Bottom - 1, $script:py))) $view.ClientSize.Width $view.ClientSize.Height $b
        # Step just outside the image in the direction the cursor left.
        $out = Px 10
        $vx = $v.X; $vy = $v.Y
        if ($overX -lt 0) { $vx -= $out } elseif ($overX -gt 0) { $vx += $out }
        if ($overY -lt 0) { $vy -= $out } elseif ($overY -gt 0) { $vy += $out }
        $sp = $view.PointToScreen((New-Object Drawing.Point([int]$vx, [int]$vy)))
        [SvNative]::SetCursorPos($sp.X, $sp.Y) | Out-Null
    }
    Write-ViewerLog "exit remote"
}

# --- main loop ------------------------------------------------------------------------------
[SvNative]::timeBeginPeriod(1) | Out-Null
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 16
$timer.Add_Tick({
    $s = Get-SecondScreen
    if (-not $s) {
        $script:remote = $false
        Release-CursorLock
        $form.Text = "Test screen (display removed)"
        return
    }
    $b = $s.Bounds
    $now = $script:clock.ElapsedMilliseconds
    $cur = [Windows.Forms.Cursor]::Position
    # Drain the raw motion and the hotkey every tick so old motion never counts later.
    $rawX = $script:input.TakeX(); $rawY = $script:input.TakeY()
    $hotkey = $script:input.TakeHotkey()
    if ($script:remote -and $hotkey) {
        Write-ViewerLog "exit by hotkey"
        Exit-Remote $b 0 0
    }
    if ($script:remote) {
        $dx = $cur.X - $script:lastX
        $dy = $cur.Y - $script:lastY
        if ($dx -ne 0 -or $dy -ne 0) {
            $scale = [Math]::Min($view.ClientSize.Width / $b.Width, $view.ClientSize.Height / $b.Height)
            if ($scale -le 0) { $scale = 1 }
            $script:px += $dx / $scale
            $script:py += $dy / $scale
            $ox = 0; $oy = 0
            if ($script:px -lt $b.Left) { $ox = -1 } elseif ($script:px -ge $b.Right) { $ox = 1 }
            if ($script:py -lt $b.Top) { $oy = -1 } elseif ($script:py -ge $b.Bottom) { $oy = 1 }
            if (($ox -ne 0 -or $oy -ne 0) -and [Windows.Forms.Control]::MouseButtons -eq 'None') {
                Exit-Remote $b $ox $oy
            } else {
                # Inside, or a button is held (a drag keeps going): clamp to the screen.
                $script:px = [Math]::Max($b.Left, [Math]::Min($b.Right - 1, $script:px))
                $script:py = [Math]::Max($b.Top, [Math]::Min($b.Bottom - 1, $script:py))
                $script:lastX = [int][Math]::Round($script:px)
                $script:lastY = [int][Math]::Round($script:py)
                [SvNative]::SetCursorPos($script:lastX, $script:lastY) | Out-Null
            }
        }
        # At the outer edges of the desktop Windows holds the cursor still, so the motion
        # above never leaves; the raw motion still shows the hand pushing outward.
        if ($script:remote -and [Windows.Forms.Control]::MouseButtons -eq 'None') {
            $script:push = Get-EdgePush $script:lastX $script:lastY $b $rawX $rawY $script:push
            if ($script:push.OverX -ne 0 -or $script:push.OverY -ne 0) {
                Write-ViewerLog "exit by edge push $($script:push.OverX),$($script:push.OverY)"
                Exit-Remote $b $script:push.OverX $script:push.OverY
            }
        } else {
            $script:push = [pscustomobject]@{ X = 0; Y = 0 }
        }
    } elseif (-not $Smoke) {
        $over = Test-OverImage $cur
        if (-not $over) { $script:needLeave = $false }
        elseif (-not $script:needLeave -and $form.WindowState -ne 'Minimized' -and [Windows.Forms.Control]::MouseButtons -eq 'None') { Enter-Remote $cur }
    }

    Update-CursorLock $now

    # Toolbar auto-hide: always in full screen, in small mode only after the owner hid it.
    if ($tb.Visible -and ($script:full -or $script:userHid)) {
        $near = $tb.Bounds.Contains($cur)
        if (-not $near -and -not $script:full) { $near = $grip.RectangleToScreen($grip.ClientRectangle).Contains($cur) }
        if ($near) { $script:tbLastNear = $now }
        elseif (($now - $script:tbLastNear) -gt 1500) { $tb.Hide() }
    } elseif (-not $tb.Visible -and $script:full -and -not $script:remote) {
        $sb = [Windows.Forms.Screen]::FromControl($form).Bounds
        if ($cur.Y -le $sb.Top + 1 -and $sb.Contains($cur)) { Show-Toolbar }
    }

    # Faster ticks while the cursor is driven or the image fills the screen.
    $want = if ($script:remote) { 8 } else { 16 }
    if ($timer.Interval -ne $want) { $timer.Interval = $want }
    if ($form.WindowState -eq 'Minimized') { return }
    if ($script:magOk) {
        # GPU picture: ~60 fps while in use or in full screen, ~30 fps when just watching.
        $every = if ($script:remote -or $script:full) { 15 } else { 32 }
        if (($now - $script:lastFrameMs) -ge $every) {
            $script:lastFrameMs = $now
            if (-not $script:magBounds -or $script:magBounds -ne $b) { Update-MagLayout }
            [SvMag]::Show($script:mag, $b.X, $b.Y, $b.Width, $b.Height) | Out-Null
        }
    } else {
        # GDI fallback: about 20 fps in direct mode, 8 fps when idle.
        $every = if ($script:remote) { 50 } else { 125 }
        if (($now - $script:lastFrameMs) -ge $every) {
            $script:lastFrameMs = $now
            Update-GdiFrame $b
        }
    }
})

$form.Add_Shown({
    Initialize-View
    Update-ToolbarSize
    Update-Glyphs
    Show-Toolbar
    $timer.Start()
    if (-not $Smoke) { Start-ClipWatchdog }
    if ($Smoke) {
        $script:stop = New-Object Windows.Forms.Timer
        $script:stop.Interval = [Math]::Max(1, $SmokeSeconds) * 1000
        $script:stop.Add_Tick({
            $script:stop.Stop()
            $s = Get-SecondScreen
            $b = $s.Bounds
            Write-ViewerLog "smoke toolbar=$($tb.Bounds) visible=$($tb.Visible) form=$($form.Bounds)"
            try {
                $names = [SvAudio]::ProcessNamesOn($b.X, $b.Y, $b.Width, $b.Height, $PID)
                $n = [SvAudio]::SetMute([string[]]@(), $false)
                Write-ViewerLog "smoke audio ok apps-on-second=$($names -join ',') changed=$n"
            } catch { Write-ViewerLog "smoke audio failed: $($_.Exception.Message)" }
            $form.Close()
        })
        $script:stop.Start()
    }
})
$form.Add_FormClosed({
    $timer.Stop()
    Release-CursorLock
    if ($script:muted.Count) { try { [SvAudio]::SetMute([string[]]$script:muted, $false) | Out-Null } catch {} }
    $script:input.Close()
    if ($script:magOk) { [SvMag]::Shutdown() }
    [SvNative]::timeEndPeriod(1) | Out-Null
})

[Windows.Forms.Application]::Run($form)
