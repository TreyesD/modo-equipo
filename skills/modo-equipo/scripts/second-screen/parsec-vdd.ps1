param(
    [switch]$SelfTest,
    [switch]$Ensure,
    [switch]$Release,
    [switch]$Status,
    [switch]$Keep,
    [string]$ScreenId = '',
    [int[]]$HolderPid = @(),
    [int]$IdleMinutes = 10,
    [int]$SpareMinutes = 720,
    [int]$TimeoutSeconds = 20
)
# Talks to the installed Parsec Virtual Display Driver directly, the same way the
# ParsecVDisplay app does, so a virtual second screen can be added with no app window.
# Dot-source it (". .\parsec-vdd.ps1") to get the [ModoEquipo.ParsecVdd] type, run it with
# -Ensure / -Release / -Status to use the background screen keeper (see below), or with
# -SelfTest to check the IOCTL constants, the keeper rules and the driver state without adding
# any display.
#
# Protocol taken from parsec-vdd.h (https://github.com/nomi-san/parsec-vdd, core/parsec-vdd.h,
# Copyright (c) 2023 Nguyen Duy, BSD 2-Clause; see NOTICE):
#   - device interface GUID {00b41627-04c4-429e-a26e-0265cf50c8fa}, opened through SetupAPI
#     with CreateFile(GENERIC_READ|GENERIC_WRITE, overlapped)
#   - every IOCTL sends a zeroed 32-byte input buffer and reads one DWORD back
#   - ADD 0x0022e004 returns the new display index; REMOVE 0x0022a008 takes that index as a
#     16-bit big-endian value; UPDATE 0x0022a00c is the keep-alive ping; VERSION 0x0022e010
#   - the driver drops displays when UPDATE stops: it must be sent at least every 100 ms
#     (this module pings every 50 ms from a background thread)
# If the process dies, pings stop and the driver removes the display on its own.

$script:VddScript = $MyInvocation.MyCommand.Path

if (-not ('ModoEquipo.ParsecVdd' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

namespace ModoEquipo {
public sealed class ParsecVdd : IDisposable {
    public static readonly Guid InterfaceGuid = new Guid("00b41627-04c4-429e-a26e-0265cf50c8fa");
    public const uint IoctlAdd = 0x0022e004;
    public const uint IoctlRemove = 0x0022a008;
    public const uint IoctlUpdate = 0x0022a00c;
    public const uint IoctlVersion = 0x0022e010;
    public const int PingMs = 50;

    // CTL_CODE(DeviceType, Function, Method, Access) from winioctl.h, for the self-test.
    public static uint CtlCode(uint deviceType, uint function, uint method, uint access) {
        return (deviceType << 16) | (access << 14) | (function << 2) | method;
    }
    // REMOVE wants the display index as a 16-bit big-endian value.
    public static byte[] RemovePayload(int index) {
        return new byte[] { (byte)((index >> 8) & 0xFF), (byte)(index & 0xFF) };
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }

    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr SetupDiGetClassDevsW(ref Guid classGuid, IntPtr enumerator, IntPtr hwndParent, uint flags);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr devInfo, IntPtr devInfoData, ref Guid guid, uint index, ref SP_DEVICE_INTERFACE_DATA data);
    [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool SetupDiGetDeviceInterfaceDetailW(IntPtr devInfo, ref SP_DEVICE_INTERFACE_DATA data, IntPtr detail, int detailSize, out int requiredSize, IntPtr devInfoData);
    [DllImport("setupapi.dll", SetLastError = true)]
    static extern bool SetupDiDestroyDeviceInfoList(IntPtr devInfo);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateEventW(IntPtr sec, bool manualReset, bool initialState, IntPtr name);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(IntPtr h, uint code, IntPtr inBuf, int inSize, IntPtr outBuf, int outSize, IntPtr returned, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetOverlappedResultEx(IntPtr h, IntPtr overlapped, out int transferred, uint timeoutMs, bool alertable);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetOverlappedResult(IntPtr h, IntPtr overlapped, out int transferred, bool wait);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CancelIoEx(IntPtr h, IntPtr overlapped);
    [DllImport("user32.dll")]
    static extern int GetSystemMetrics(int index);

    const uint DIGCF_PRESENT = 0x2, DIGCF_DEVICEINTERFACE = 0x10;
    static readonly IntPtr Invalid = new IntPtr(-1);

    public static int MonitorCount() { return GetSystemMetrics(80); } // SM_CMONITORS

    // Device path of the driver's interface, or null when the driver is not installed/running.
    public static string FindDevicePath() {
        Guid g = InterfaceGuid;
        IntPtr info = SetupDiGetClassDevsW(ref g, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (info == Invalid) return null;
        try {
            var data = new SP_DEVICE_INTERFACE_DATA();
            data.cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
            for (uint i = 0; SetupDiEnumDeviceInterfaces(info, IntPtr.Zero, ref g, i, ref data); i++) {
                int size;
                SetupDiGetDeviceInterfaceDetailW(info, ref data, IntPtr.Zero, 0, out size, IntPtr.Zero);
                if (size <= 0) continue;
                IntPtr buf = Marshal.AllocHGlobal(size);
                try {
                    Marshal.WriteInt32(buf, IntPtr.Size == 8 ? 8 : 6); // sizeof(SP_DEVICE_INTERFACE_DETAIL_DATA_W)
                    if (SetupDiGetDeviceInterfaceDetailW(info, ref data, buf, size, out size, IntPtr.Zero))
                        return Marshal.PtrToStringUni(IntPtr.Add(buf, 4));
                } finally { Marshal.FreeHGlobal(buf); }
            }
            return null;
        } finally { SetupDiDestroyDeviceInfoList(info); }
    }

    IntPtr handle;
    readonly object ioLock = new object();
    readonly List<int> added = new List<int>();
    Thread pinger;
    volatile bool stopping;
    public int FailedPings;

    ParsecVdd(IntPtr h) { handle = h; }

    // Opens the driver. Throws with a readable message when it is missing or refuses access.
    public static ParsecVdd Open() {
        string path = FindDevicePath();
        if (path == null) throw new InvalidOperationException("Parsec Virtual Display Driver not found (no device interface).");
        IntPtr h = CreateFileW(path, 0xC0000000, 0x3, IntPtr.Zero, 3, 0x80 | 0x20000000 | 0x40000000 | 0x80000000, IntPtr.Zero);
        if (h == Invalid || h == IntPtr.Zero)
            throw new InvalidOperationException("Could not open the Parsec Virtual Display Driver (Win32 error " + Marshal.GetLastWin32Error() + ").");
        return new ParsecVdd(h);
    }

    // One IOCTL as parsec-vdd.h sends it. Returns the DWORD answer, or -1 on failure.
    int Io(uint code, byte[] payload) {
        lock (ioLock) {
            if (handle == IntPtr.Zero) return -1;
            int ovSize = 2 * IntPtr.Size + 8 + IntPtr.Size;
            IntPtr inBuf = Marshal.AllocHGlobal(32), outBuf = Marshal.AllocHGlobal(4), ov = Marshal.AllocHGlobal(ovSize);
            IntPtr ev = CreateEventW(IntPtr.Zero, true, false, IntPtr.Zero);
            try {
                for (int i = 0; i < 32; i++) Marshal.WriteByte(inBuf, i, 0);
                if (payload != null) Marshal.Copy(payload, 0, inBuf, Math.Min(payload.Length, 32));
                Marshal.WriteInt32(outBuf, 0);
                for (int i = 0; i < ovSize; i++) Marshal.WriteByte(ov, i, 0);
                Marshal.WriteIntPtr(ov, 2 * IntPtr.Size + 8, ev);
                DeviceIoControl(handle, code, inBuf, 32, outBuf, 4, IntPtr.Zero, ov);
                int n;
                if (!GetOverlappedResultEx(handle, ov, out n, 5000, false)) {
                    CancelIoEx(handle, ov);
                    GetOverlappedResult(handle, ov, out n, true); // buffers must outlive the request
                    return -1;
                }
                return Marshal.ReadInt32(outBuf);
            } finally {
                if (ev != IntPtr.Zero) CloseHandle(ev);
                Marshal.FreeHGlobal(inBuf); Marshal.FreeHGlobal(outBuf); Marshal.FreeHGlobal(ov);
            }
        }
    }

    public int Version() { return Io(IoctlVersion, null); }
    public bool Ping() { return Io(IoctlUpdate, null) != -1; }

    // Adds one virtual display and starts the keep-alive thread. Returns the display index.
    // Right after a display was removed the driver sometimes refuses the next ADD (measured: about
    // one in four quick add/remove cycles); a later try works, so it retries for up to ~6 s.
    public int LastAddAttempts;
    static readonly int[] AddRetryMs = { 250, 500, 1000, 1500, 2500 };
    public int AddDisplay() {
        int index = Io(IoctlAdd, null);
        LastAddAttempts = 1;
        for (int i = 0; index < 0 && i < AddRetryMs.Length; i++) {
            Ping();
            Thread.Sleep(AddRetryMs[i]);
            index = Io(IoctlAdd, null);
            LastAddAttempts++;
        }
        if (index < 0) throw new InvalidOperationException("The driver refused to add a display (" + LastAddAttempts + " tries).");
        Ping();
        lock (added) added.Add(index);
        StartPinger();
        return index;
    }

    public void RemoveDisplay(int index) {
        Io(IoctlRemove, RemovePayload(index));
        Ping();
        lock (added) added.Remove(index);
    }

    void StartPinger() {
        if (pinger != null) return;
        pinger = new Thread(() => {
            while (!stopping) {
                if (!Ping()) Interlocked.Increment(ref FailedPings);
                Thread.Sleep(PingMs);
            }
        });
        pinger.IsBackground = true; // never keeps the process alive on its own
        pinger.Name = "parsec-vdd keep-alive";
        pinger.Start();
    }

    // Removes the displays this object added, stops the pings and closes the driver.
    public void Dispose() {
        int[] mine;
        lock (added) mine = added.ToArray();
        foreach (int i in mine) RemoveDisplay(i);
        stopping = true;
        if (pinger != null) pinger.Join(1000);
        lock (ioLock) { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
    }
}
}
'@
}

# ==========================================================================================
# Screen keeper: one hidden background process that gives every test-screen session its own
# virtual monitor for as long as that session needs it (the viewer, a test runner, an app placed
# there), and keeps the mouse on the real screens while any virtual screen exists.
#
#   parsec-vdd.ps1 -Ensure [-ScreenId <id>] [-HolderPid <pid>,...] [-IdleMinutes N]
#       Makes sure session <id> has its own screen: starts the keeper (or reuses the running one),
#       which adds a virtual display for a new id and hands the same one back to a known id. It
#       waits for Windows to report the screen and prints one JSON line with its device name and
#       bounds. The id is -ScreenId, else the MODO_EQUIPO_SCREEN_ID environment variable, else
#       'default' ('default' first takes a second screen that already exists, such as a real
#       monitor). Holder pids keep the screen while those processes run; after the last holder
#       ends (or when none was given) the session lasts IdleMinutes (default 10) more, then its
#       display is removed. The keeper exits when no session is left. Up to 8 virtual displays
#       (VDD_MAX_DISPLAYS in parsec-vdd.h). Exit 0 = the session has a screen, 1 = it could not
#       be provided.
#   parsec-vdd.ps1 -Release -ScreenId <id>   frees that session's screen now.
#   parsec-vdd.ps1 -Release                  stops the keeper (removes all its screens).
#   parsec-vdd.ps1 -Status                   prints the keeper state (sessions, screens) as JSON.
#   parsec-vdd.ps1 -Keep                     the keeper itself (started hidden by -Ensure).
#
# A keeper that dies leaves its sessions' request files and owned.json behind; while another
# program keeps the displays alive (the ParsecVDisplay app pings every display), the next keeper
# gives each id its old display back and removes the unclaimed ones after 15 s.
#
# Mouse lock: while a virtual screen exists the keeper confines the cursor (ClipCursor) to the
# real screens, so plain movement does not drift onto the virtual ones. It lifts the clip while a
# mouse button is held (dragging a window across) and while the viewer owns the named mutex
# Local\ModoEquipo.CursorFree (its direct mode). It never replaces a clip another program set.
# The flag file <state>\lock-off turns the lock off (the viewer's lock button writes it).
# A clip outlives the process that set it, so a hidden watchdog releases it if the keeper dies.

if (-not ('ModoEquipo.CursorLock' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace ModoEquipo {
public sealed class CursorLock {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
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
    [DllImport("user32.dll")] static extern bool ClipCursor(ref RECT r);
    [DllImport("user32.dll")] static extern bool ClipCursor(IntPtr r);
    [DllImport("user32.dll")] static extern bool GetClipCursor(out RECT r);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);

    public const string FreeMutexName = @"Local\ModoEquipo.CursorFree";

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
    public static RECT Current() { RECT r; GetClipCursor(out r); return r; }
    public static RECT Desktop() {
        RECT r; r.Left = GetSystemMetrics(76); r.Top = GetSystemMetrics(77);
        r.Right = r.Left + GetSystemMetrics(78); r.Bottom = r.Top + GetSystemMetrics(79); return r;
    }
    static bool Same(RECT a, RECT b) { return a.Left == b.Left && a.Top == b.Top && a.Right == b.Right && a.Bottom == b.Bottom; }
    // Physical buttons (GetAsyncKeyState reads the device, so swapped buttons do not matter here).
    public static bool AnyButtonDown() {
        return (GetAsyncKeyState(0x01) & 0x8000) != 0 || (GetAsyncKeyState(0x02) & 0x8000) != 0 || (GetAsyncKeyState(0x04) & 0x8000) != 0;
    }

    readonly object gate = new object();
    readonly Mutex free = new Mutex(false, FreeMutexName);
    RECT home; bool hasHome, mine;
    volatile bool enabled = true, stopping;
    Thread thread;

    public bool Enabled { get { return enabled; } set { enabled = value; } }
    public bool Engaged { get { lock (gate) return mine; } }
    public string HomeText { get { lock (gate) return hasHome ? home.Left + "," + home.Top + "," + home.Right + "," + home.Bottom : ""; } }

    public void SetHome(int x, int y, int w, int h) {
        lock (gate) {
            RECT r; r.Left = x; r.Top = y; r.Right = x + w; r.Bottom = y + h;
            if (hasHome && Same(r, home)) return;
            ReleaseMine();
            home = r; hasHome = true;
        }
    }
    public void ClearHome() { lock (gate) { ReleaseMine(); hasHome = false; } }

    // True while the viewer holds the mutex (direct mode). An abandoned mutex (the viewer died
    // in direct mode) counts as free again.
    bool ViewerOwnsCursor() {
        try {
            if (free.WaitOne(0)) { free.ReleaseMutex(); return false; }
            return true;
        } catch (AbandonedMutexException) {
            try { free.ReleaseMutex(); } catch { }
            return false;
        }
    }

    void ReleaseMine() {
        if (mine && hasHome && Same(Current(), home)) ClipCursor(IntPtr.Zero);   // only our own clip
        mine = false;
    }

    public void Step() {
        lock (gate) {
            bool want = enabled && hasHome && !AnyButtonDown() && !ViewerOwnsCursor();
            if (!want) { ReleaseMine(); return; }
            RECT c = Current();
            if (Same(c, home)) { mine = true; return; }
            // Re-apply only when nobody holds a clip (the clip is the whole desktop): never
            // fight a program that confines the cursor itself, for example a game.
            if (Same(c, Desktop())) { RECT h = home; ClipCursor(ref h); mine = true; }
        }
    }

    public void Start() {
        if (thread != null) return;
        thread = new Thread(() => { while (!stopping) { try { Step(); } catch { } Thread.Sleep(10); } });
        thread.IsBackground = true;
        thread.Name = "cursor lock";
        thread.Start();
    }
    public void Stop() {
        stopping = true;
        if (thread != null) thread.Join(500);
        lock (gate) ReleaseMine();
    }
}
}
'@
}

# This keeper (per-session screens) has its own state folder and kernel names ("-v2"), so it can
# run next to an older one-screen keeper that is still alive: the old one keeps the screen it
# holds for whoever uses it and is never shared with new sessions. MODO_EQUIPO_KEEPER_TAG adds
# one more separate keeper (for tests), so a development copy can run next to the real one.
$script:KeeperTag = '-v2' + $(if ($env:MODO_EQUIPO_KEEPER_TAG -match '^[A-Za-z0-9_-]{1,20}$') { "-$($env:MODO_EQUIPO_KEEPER_TAG)" } else { '' })
$script:KeeperDir = Join-Path $env:USERPROFILE ".claude\modo-equipo\screen-keeper$script:KeeperTag"
$script:SessionDir = Join-Path $script:KeeperDir 'sessions'
$script:KeeperMutexName = "Local\ModoEquipo.ScreenKeeper$script:KeeperTag"
$script:KeeperStopName = "Local\ModoEquipo.ScreenKeeper$script:KeeperTag.Stop"
$script:MaxDisplays = 8   # VDD_MAX_DISPLAYS in parsec-vdd.h (the adapter takes 16; half avoids plugging lag)
$script:KeeperVersion = 2

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

# Holder pids that are still running (the alive test is a parameter so the self-test can fake it).
function Get-LiveHolders([int[]]$pids, [scriptblock]$IsAlive) {
    @($pids | Where-Object { $_ -gt 0 } | Select-Object -Unique | Where-Object { & $IsAlive $_ })
}
$script:IsAlive = { param($p) [bool](Get-Process -Id $p -ErrorAction SilentlyContinue) }

# A session (and the keeper's legacy single screen) ends after IdleMinutes with no live holder.
function Test-KeeperIdle([int]$liveCount, [double]$idleSinceMs, [double]$nowMs, [double]$idleMinutes) {
    return ($liveCount -eq 0 -and ($nowMs - $idleSinceMs) -ge $idleMinutes * 60000)
}

# Screen id of the caller: -ScreenId, else MODO_EQUIPO_SCREEN_ID, else the Claude Code session
# it runs in ("cc-" + the first 8 characters of CLAUDE_CODE_SESSION_ID, so every Claude session
# gets its own screen with no setup), else 'default'.
function Resolve-ScreenId([string]$id) {
    if (-not $id) { $id = $env:MODO_EQUIPO_SCREEN_ID }
    if (-not $id -and $env:CLAUDE_CODE_SESSION_ID -match '^[A-Za-z0-9-]{8,}$') { $id = 'cc-' + $env:CLAUDE_CODE_SESSION_ID.Substring(0, 8) }
    if (-not $id) { $id = 'default' }
    if ($id -notmatch '^[A-Za-z0-9._-]{1,40}$') { throw "Invalid screen id '$id' (letters, digits, '.', '_' or '-', up to 40)." }
    return $id.ToLowerInvariant()
}

# Which screen a new session gets. $screens: Name/Primary/Virtual; $assigned: device names other
# sessions hold; $orphans: displays this keeper owns with no session (index, device, id).
#   1. its own display, left from before a keeper restart
#   2. 'default' only: a second screen that is already there (a real monitor, or a virtual one
#      another program added); it is shared with nobody and never removed by the keeper
#   3. any other display the keeper owns and nobody uses
#   4. a new display
function Select-ScreenFor([string]$id, $screens, [string[]]$assigned, $orphans) {
    $present = @($screens | ForEach-Object { $_.Name })
    $free = @($orphans | Where-Object { $present -contains $_.device -and $assigned -notcontains $_.device })
    $own = @($free | Where-Object { $_.id -eq $id })
    if ($own.Count) { return [pscustomobject]@{ Kind = 'orphan'; Device = $own[0].device; Index = [int]$own[0].index } }
    if ($id -eq 'default') {
        $orphanNames = @($orphans | ForEach-Object { $_.device })
        $there = @($screens | Where-Object { -not $_.Primary -and $assigned -notcontains $_.Name -and $orphanNames -notcontains $_.Name })
        if ($there.Count) { return [pscustomobject]@{ Kind = 'adopt'; Device = $there[0].Name; Index = -1 } }
    }
    if ($free.Count) { return [pscustomobject]@{ Kind = 'orphan'; Device = $free[0].device; Index = [int]$free[0].index } }
    return [pscustomobject]@{ Kind = 'add'; Device = $null; Index = -1 }
}

# Fresh screen list (WinForms caches it; a process without a message loop never sees changes).
function Get-ScreenList {
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.Screen].GetField('screens', [Reflection.BindingFlags]'NonPublic,Static').SetValue($null, $null)
    @([Windows.Forms.Screen]::AllScreens | ForEach-Object {
        [pscustomobject]@{ Name = $_.DeviceName; Primary = $_.Primary; Bounds = $_.Bounds; Virtual = [ModoEquipo.CursorLock]::IsVirtual($_.DeviceName) }
    })
}

function Test-KeeperRunning {
    $m = $null
    try { return [Threading.Mutex]::TryOpenExisting($script:KeeperMutexName, [ref]$m) } finally { if ($m) { $m.Dispose() } }
}

# Pid files: one pid per line. Appends retry briefly because the keeper rewrites the file.
function Add-PidFile([string]$file, [int[]]$pids) {
    New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
    $text = (($pids | Where-Object { $_ -gt 0 } | ForEach-Object { "$_`r`n" }) -join '')
    for ($i = 0; $i -lt 20; $i++) {
        try { [IO.File]::AppendAllText($file, $text); return } catch { Start-Sleep -Milliseconds 50 }
    }
}
function Read-PidFile([string]$file) {
    if (-not (Test-Path $file)) { return @() }
    try { @([IO.File]::ReadAllLines($file) | ForEach-Object { $n = 0; if ([int]::TryParse($_.Trim(), [ref]$n)) { $n } }) } catch { @() }
}
function Write-PidFile([string]$file, [int[]]$pids) {
    try { [IO.File]::WriteAllText($file, (($pids | ForEach-Object { "$_`r`n" }) -join '')) } catch {}
}

function Read-KeeperState {
    $sf = Join-Path $script:KeeperDir 'keeper.json'
    if (-not (Test-Path $sf)) { return $null }
    for ($i = 0; $i -lt 5; $i++) {
        try { return (Get-Content $sf -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { Start-Sleep -Milliseconds 40 }
    }
    return $null
}

function ConvertTo-ScreenInfo($s) {
    if (-not $s) { return $null }
    [pscustomobject]@{ name = $s.Name; primary = $s.Primary; virtual = $s.Virtual; x = $s.Bounds.X; y = $s.Bounds.Y; width = $s.Bounds.Width; height = $s.Bounds.Height }
}

function Get-KeeperStatus {
    $running = [bool](Test-KeeperRunning)
    $state = if ($running) { Read-KeeperState } else { $null }
    $screens = Get-ScreenList
    [pscustomobject]@{
        keeper       = $running
        version      = $(if ($state -and $state.version) { $state.version } elseif ($state) { 1 } else { $null })
        pid          = $(if ($state) { $state.pid } else { $null })
        sessions     = @($(if ($state -and $state.sessions) { $state.sessions }))
        errors       = @($(if ($state -and $state.errors) { $state.errors }))
        lockArea     = $(if ($state) { $state.lockArea } else { '' })
        lockOn       = -not (Test-Path (Join-Path $script:KeeperDir 'lock-off'))
        secondScreen = [bool]@($screens | Where-Object { -not $_.Primary }).Count
        screens      = @($screens | ForEach-Object { ConvertTo-ScreenInfo $_ })
    }
}

function New-EnsureResult([string]$id, [string]$keeper, $screen, [bool]$shared) {
    $i = ConvertTo-ScreenInfo $screen
    [pscustomobject]@{ ok = $true; secondScreen = $true; keeper = $keeper; id = $id; screen = $i.name; x = $i.x; y = $i.y; width = $i.width; height = $i.height; shared = $shared }
}

# The driver's device exists but its interface is gone: the driver host crashed (Windows event
# 10111 "offline due to a user-mode driver crash") and stays down until the device is restarted.
# Told apart from "not installed" so nobody reinstalls or starts other tools for nothing.
function Test-DriverOffline {
    try {
        $d = @(Get-PnpDevice -Class Display -ErrorAction Stop | Where-Object { $_.InstanceId -like 'ROOT\DISPLAY\*' -and $_.FriendlyName -like '*Parsec*' })
        return ($d.Count -gt 0)
    } catch { return $false }
}

function Invoke-Ensure([string]$id, [int[]]$holders, [int]$idleMinutes, [int]$timeoutSeconds) {
    $screens = Get-ScreenList
    $second = @($screens | Where-Object { -not $_.Primary })
    $virtual = @($second | Where-Object { $_.Virtual })
    $running = Test-KeeperRunning
    # 'default' with a real second monitor and no virtual one: nothing to keep and nothing to lock.
    if ($id -eq 'default' -and $second.Count -gt 0 -and $virtual.Count -eq 0 -and -not $running) {
        return New-EnsureResult $id 'not-needed' $second[0] $false
    }
    if (-not $running -and -not [ModoEquipo.ParsecVdd]::FindDevicePath()) {
        if ($second.Count) { return New-EnsureResult $id 'no-driver' $second[0] $true }   # every session shares it
        if (Test-DriverOffline) {
            return [pscustomobject]@{ ok = $false; secondScreen = $false; keeper = 'none'; id = $id; driverOffline = $true
                error = 'The Parsec Virtual Display Driver is installed but offline (its driver host crashed). Restart it: run "pnputil /restart-device ROOT\DISPLAY\0000" in an administrator terminal, or reboot. Nothing else to clean up.' }
        }
        return [pscustomobject]@{ ok = $false; secondScreen = $false; keeper = 'none'; id = $id; error = 'Parsec Virtual Display Driver not installed (see references/second-screen.md, option B).' }
    }
    $request = Join-Path $script:SessionDir "$id.txt"
    Remove-Item (Join-Path $script:SessionDir "$id.release") -ErrorAction SilentlyContinue
    Add-PidFile $request $holders
    $how = 'running'
    if (-not $running) {
        $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argLine = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:VddScript`" -Keep -IdleMinutes $idleMinutes"
        Start-Process -FilePath $ps -ArgumentList $argLine -WindowStyle Hidden | Out-Null
        $how = 'started'
    }
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $since = Get-Date
    do {
        $state = Read-KeeperState
        if ($state) {
            $s = @($state.sessions | Where-Object { $_.id -eq $id })
            if ($s.Count) {
                $scr = @(Get-ScreenList | Where-Object { $_.Name -eq $s[0].device })
                if ($scr.Count) { return New-EnsureResult $id $how $scr[0] $false }
            }
            $e = @($state.errors | Where-Object { $_.id -eq $id -and [datetime]$_.at -ge $since.AddSeconds(-2) })
            if ($e.Count) { return [pscustomobject]@{ ok = $false; secondScreen = $false; keeper = $how; id = $id; error = $e[0].error } }
        }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    $log = Join-Path $script:KeeperDir 'keeper.log'
    $last = if (Test-Path $log) { (Get-Content $log -Tail 1) } else { '' }
    return [pscustomobject]@{ ok = $false; secondScreen = $false; keeper = $how; id = $id; error = "no screen for '$id' after $timeoutSeconds s. $last" }
}

# -Release -ScreenId <id> frees that session's screen; -Release alone stops the keeper.
function Invoke-Release([string]$id) {
    if (-not (Test-KeeperRunning)) { return [pscustomobject]@{ ok = $true; keeper = 'none'; id = $id } }
    if ($id) {
        New-Item -ItemType Directory -Force -Path $script:SessionDir | Out-Null
        Set-Content -Path (Join-Path $script:SessionDir "$id.release") -Value '1'
        $deadline = (Get-Date).AddSeconds(8)
        do {
            $state = Read-KeeperState
            if ($state -and -not @($state.sessions | Where-Object { $_.id -eq $id }).Count -and -not (Test-Path (Join-Path $script:SessionDir "$id.txt"))) {
                return [pscustomobject]@{ ok = $true; keeper = 'running'; id = $id; released = $true }
            }
            Start-Sleep -Milliseconds 200
        } while ((Get-Date) -lt $deadline -and (Test-KeeperRunning))
        return [pscustomobject]@{ ok = -not (Test-KeeperRunning) -or -not (Test-Path (Join-Path $script:SessionDir "$id.txt")); keeper = $(if (Test-KeeperRunning) { 'running' } else { 'stopped' }); id = $id; released = $true }
    }
    $ev = $null
    try {
        if ([Threading.EventWaitHandle]::TryOpenExisting($script:KeeperStopName, [ref]$ev)) { [void]$ev.Set() }
    } finally { if ($ev) { $ev.Dispose() } }
    $deadline = (Get-Date).AddSeconds(8)
    while ((Test-KeeperRunning) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    return [pscustomobject]@{ ok = -not (Test-KeeperRunning); keeper = 'stopped' }
}

function Start-ClipWatchdog([int]$ownerPid, [string]$clipFile) {
    $code = @"
Add-Type 'using System; using System.Runtime.InteropServices; public static class W { [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; } [DllImport("user32.dll")] public static extern bool GetClipCursor(out R r); [DllImport("user32.dll")] public static extern bool ClipCursor(IntPtr r); [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v); }'
[W]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
try { Wait-Process -Id $ownerPid -ErrorAction Stop } catch {}
`$f = '$clipFile'
if (Test-Path `$f) {
    `$want = (Get-Content `$f -Raw).Trim()
    `$r = New-Object W+R; [void][W]::GetClipCursor([ref]`$r)
    if ("`$(`$r.L),`$(`$r.T),`$(`$r.Rt),`$(`$r.B)" -eq `$want) { [void][W]::ClipCursor([IntPtr]::Zero) }
    Remove-Item `$f -ErrorAction SilentlyContinue
}
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $enc" -WindowStyle Hidden | Out-Null
}

# Waits for Windows to report a virtual screen that was not in $before.
function Wait-NewScreen([string[]]$before, [int]$ms) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        $new = @(Get-ScreenList | Where-Object { $_.Virtual -and -not $_.Primary -and $before -notcontains $_.Name })
        if ($new.Count) { return $new[0] }
        Start-Sleep -Milliseconds 200
    } while ($sw.ElapsedMilliseconds -lt $ms)
    return $null
}

function Invoke-Keeper([int]$idleMinutes, [int]$SpareMinutes = 720) {
    New-Item -ItemType Directory -Force -Path $script:SessionDir | Out-Null
    $log = Join-Path $script:KeeperDir 'keeper.log'
    function KLog($t) { try { Add-Content -Path $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $t" } catch {} }
    $created = $false
    $single = New-Object Threading.Mutex($true, $script:KeeperMutexName, [ref]$created)
    if (-not $created) { $single.Dispose(); return }   # another keeper already runs
    Set-Content -Path $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') keeper start pid=$PID idle=${idleMinutes}min version=$script:KeeperVersion"
    [void][ModoEquipo.CursorLock]::SetProcessDpiAwarenessContext([IntPtr](-4))   # physical pixels
    $stop = New-Object Threading.EventWaitHandle($false, 'ManualReset', $script:KeeperStopName)
    $clipFile = Join-Path $script:KeeperDir 'clip.txt'
    $stateFile = Join-Path $script:KeeperDir 'keeper.json'
    $ownedFile = Join-Path $script:KeeperDir 'owned.json'
    $offFile = Join-Path $script:KeeperDir 'lock-off'
    $lock = New-Object ModoEquipo.CursorLock
    $sess = @{}       # id -> session (Id, Device, Index, Ours, IdleSince, Holders)
    $errors = @{}     # id -> @{ error; at; ms }
    # Displays a keeper that died left behind (another program, such as the ParsecVDisplay app,
    # kept pinging them): this keeper owns them now and hands them out again or removes them.
    $orphans = @()
    if (Test-Path $ownedFile) {
        try { $orphans = @(Get-Content $ownedFile -Raw | ConvertFrom-Json | Where-Object { $_.device }) } catch {}
        $present = @(Get-ScreenList | Where-Object { $_.Virtual } | ForEach-Object { $_.Name })
        $orphans = @($orphans | Where-Object { $present -contains $_.device })
        if ($orphans.Count) { KLog "took over $($orphans.Count) display(s) left by a previous keeper: $(($orphans | ForEach-Object { "$($_.device)#$($_.index)" }) -join ' ')" }
    }
    function Save-Owned {
        $list = @($sess.Values | Where-Object { $_.Ours } | ForEach-Object { [pscustomobject]@{ index = $_.Index; device = $_.Device; id = $_.Id } }) + @($orphans)
        try { ConvertTo-Json -InputObject @($list) -Compress | Set-Content -Path $ownedFile } catch {}
    }
    function Remove-Owned([int]$index) {
        try {
            if (-not $script:vddRef) { $script:vddRef = [ModoEquipo.ParsecVdd]::Open() }
            $script:vddRef.RemoveDisplay($index)
        } catch { KLog "cannot remove display index=${index}: $($_.Exception.Message)" }
    }
    $script:vddRef = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        Start-ClipWatchdog $PID $clipFile
        $lock.Start()
        while (-not $stop.WaitOne(1000)) {
            $now = $clock.ElapsedMilliseconds
            $screens = Get-ScreenList
            $names = @($screens | ForEach-Object { $_.Name })
            $orphans = @($orphans | Where-Object { $names -contains $_.device })
            $ids = @(Get-ChildItem -Path $script:SessionDir -Filter '*.txt' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName.ToLowerInvariant() })

            # 1. Every requested id gets its own screen (re-added if it went away).
            foreach ($id in $ids) {
                $s = $sess[$id]
                if ($s -and $names -notcontains $s.Device) {
                    KLog "screen $($s.Device) of '$id' went away"
                    $sess.Remove($id); $s = $null
                }
                if ($s) { continue }
                if ($errors[$id] -and ($now - $errors[$id].ms) -lt 10000) { continue }   # retry failures every 10 s
                $pick = Select-ScreenFor $id $screens @($sess.Values | ForEach-Object { $_.Device }) $orphans
                if ($pick.Kind -eq 'add') {
                    $owned = @($sess.Values | Where-Object { $_.Ours }).Count + $orphans.Count
                    if ($owned -ge $script:MaxDisplays) {
                        $errors[$id] = @{ error = "all $script:MaxDisplays virtual displays are in use"; at = (Get-Date -Format s); ms = $now }
                        KLog "no screen for '$id': $($errors[$id].error)"
                        continue
                    }
                    try {
                        if (-not $script:vddRef) { $script:vddRef = [ModoEquipo.ParsecVdd]::Open() }
                        $index = $script:vddRef.AddDisplay()
                        $new = Wait-NewScreen $names 10000
                        if (-not $new) { $script:vddRef.RemoveDisplay($index); throw "Windows did not show the new display within 10 s" }
                        $pick = [pscustomobject]@{ Kind = 'add'; Device = $new.Name; Index = $index }
                        $screens = Get-ScreenList; $names = @($screens | ForEach-Object { $_.Name })
                    } catch {
                        $errors[$id] = @{ error = "cannot add a display: $($_.Exception.Message)"; at = (Get-Date -Format s); ms = $now }
                        KLog "no screen for '$id': $($errors[$id].error)"
                        continue
                    }
                }
                if ($pick.Kind -eq 'orphan') { $orphans = @($orphans | Where-Object { $_.device -ne $pick.Device }) }
                $sess[$id] = [pscustomobject]@{ Id = $id; Device = $pick.Device; Index = $pick.Index; Ours = ($pick.Kind -ne 'adopt'); IdleSince = $now; Holders = @(); Created = (Get-Date -Format s) }
                $errors.Remove($id)
                $b = ($screens | Where-Object { $_.Name -eq $pick.Device } | Select-Object -First 1).Bounds
                KLog "'$id' -> $($pick.Device) ($($pick.Kind), index=$($pick.Index), at $($b.X),$($b.Y) $($b.Width)x$($b.Height))"
                Save-Owned
            }

            # 2. Holders, releases and idle sessions.
            foreach ($id in @($sess.Keys)) {
                $s = $sess[$id]
                $file = Join-Path $script:SessionDir "$id.txt"
                $why = $null
                if (Test-Path (Join-Path $script:SessionDir "$id.release")) { $why = 'released' }
                elseif (-not (Test-Path $file)) { $why = 'request removed' }
                else {
                    $listed = @(Read-PidFile $file)
                    $live = Get-LiveHolders $listed $script:IsAlive
                    if ($live.Count -ne $listed.Count) { Write-PidFile $file $live }
                    $s.Holders = $live
                    if ($live.Count) { $s.IdleSince = $now }
                    elseif (Test-KeeperIdle 0 $s.IdleSince $now $idleMinutes) { $why = "no holder for $idleMinutes min" }
                }
                if ($why) {
                    # Adding or removing a monitor makes Windows rebuild the display topology, which can
                    # flash every screen. So a freed display is NOT removed: it stays as a spare that the
                    # next session takes over, and is removed only after $SpareMinutes (12 h) unused, on
                    # -Release, or when the keeper stops.
                    if ($s.Ours) { $orphans = @($orphans) + @([pscustomobject]@{ index = $s.Index; device = $s.Device; id = ''; spareSince = (Get-Date -Format s) }) }
                    $sess.Remove($id)
                    foreach ($f in "$id.txt", "$id.release") { Remove-Item (Join-Path $script:SessionDir $f) -ErrorAction SilentlyContinue }
                    KLog "freed $($s.Device) of '$id' ($why)"
                    Save-Owned
                }
            }
            # Requests that failed are dropped (the caller got the error); stray release files too.
            foreach ($id in @($errors.Keys)) {
                if (($now - $errors[$id].ms) -ge 60000) { $errors.Remove($id) }
                elseif (-not $sess[$id]) { Remove-Item (Join-Path $script:SessionDir "$id.txt") -ErrorAction SilentlyContinue }
            }
            Get-ChildItem -Path $script:SessionDir -Filter '*.release' -ErrorAction SilentlyContinue |
                Where-Object { -not $sess[$_.BaseName.ToLowerInvariant()] } | Remove-Item -ErrorAction SilentlyContinue
            # Displays left by a previous keeper that nobody claimed are removed; spares kept after a
            # release are removed only when they have been unused for $SpareMinutes.
            if ($orphans.Count) {
                $drop = @($orphans | Where-Object {
                    if ($_.spareSince) { ((Get-Date) - [datetime]$_.spareSince).TotalMinutes -ge $SpareMinutes }
                    else { $clock.ElapsedMilliseconds -ge 15000 }
                })
                foreach ($o in $drop) { Remove-Owned ([int]$o.index); KLog "removed unused display $($o.device)#$($o.index)" }
                if ($drop.Count) { $orphans = @($orphans | Where-Object { $drop -notcontains $_ }); Save-Owned }
            }

            # 3. Mouse lock area: the real screens, whatever the number of virtual ones.
            $screens = Get-ScreenList
            $h = Get-HomeRect $screens
            if ($h) { $lock.SetHome($h.X, $h.Y, $h.Width, $h.Height) } else { $lock.ClearHome() }
            $lock.Enabled = -not (Test-Path $offFile)
            try {
                if ($lock.Engaged) { Set-Content -Path $clipFile -Value $lock.HomeText } elseif (Test-Path $clipFile) { Remove-Item $clipFile }
            } catch {}

            # 4. State for -Ensure / -Status / the viewer.
            try {
                $list = @($sess.Values | Sort-Object Id | ForEach-Object {
                    $sd = $_.Device; $sb = ($screens | Where-Object { $_.Name -eq $sd } | Select-Object -First 1).Bounds
                    [pscustomobject]@{ id = $_.Id; device = $_.Device; index = $_.Index; owned = $_.Ours; created = $_.Created; holders = @($_.Holders); x = $sb.X; y = $sb.Y; width = $sb.Width; height = $sb.Height }
                })
                $errs = @($errors.Keys | ForEach-Object { [pscustomobject]@{ id = $_; error = $errors[$_].error; at = $errors[$_].at } })
                [pscustomobject]@{ version = $script:KeeperVersion; pid = $PID; sessions = $list; errors = $errs; lockArea = $lock.HomeText; lockEngaged = $lock.Engaged; updated = (Get-Date -Format s) } |
                    ConvertTo-Json -Depth 4 -Compress | Set-Content -Path $stateFile
            } catch {}
            $pending = @(Get-ChildItem -Path $script:SessionDir -Filter '*.txt' -ErrorAction SilentlyContinue).Count
            if ($sess.Count -eq 0 -and $pending -eq 0 -and $orphans.Count -eq 0) { KLog 'no sessions left: stopping'; break }
        }
        if ($stop.WaitOne(0)) { KLog 'stop requested' }
    } finally {
        $lock.Stop()
        foreach ($s in @($sess.Values | Where-Object { $_.Ours })) { Remove-Owned $s.Index; KLog "removed $($s.Device) of '$($s.Id)'" }
        foreach ($o in $orphans) { Remove-Owned ([int]$o.index) }
        if ($script:vddRef) { $script:vddRef.Dispose() }
        foreach ($f in $clipFile, $stateFile, $ownedFile) { Remove-Item $f -ErrorAction SilentlyContinue }
        Get-ChildItem -Path $script:SessionDir -ErrorAction SilentlyContinue | Remove-Item -ErrorAction SilentlyContinue
        KLog 'keeper stopped'
        $stop.Dispose()
        $single.ReleaseMutex(); $single.Dispose()
    }
}

if ($Ensure -or $Release -or $Status) { [void][ModoEquipo.CursorLock]::SetProcessDpiAwarenessContext([IntPtr](-4)) }
if ($Ensure) {
    try { $sid = Resolve-ScreenId $ScreenId } catch { [pscustomobject]@{ ok = $false; secondScreen = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress; exit 1 }
    $r = Invoke-Ensure $sid $HolderPid $IdleMinutes $TimeoutSeconds
    $r | ConvertTo-Json -Compress
    exit $(if ($r.ok) { 0 } else { 1 })
}
if ($Release) {
    $rid = $null
    if ($ScreenId) { try { $rid = Resolve-ScreenId $ScreenId } catch { [pscustomobject]@{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json -Compress; exit 1 } }
    Invoke-Release $rid | ConvertTo-Json -Compress; exit 0
}
if ($Status) { Get-KeeperStatus | ConvertTo-Json -Depth 5 -Compress; exit 0 }
if ($Keep) { Invoke-Keeper $IdleMinutes $SpareMinutes; exit 0 }

if ($SelfTest) {
    $fail = 0
    function Check($name, $ok) { if ($ok) { "PASS $name" } else { "FAIL $name"; $script:fail++ } }
    $T = [ModoEquipo.ParsecVdd]
    # FILE_DEVICE_UNKNOWN (0x22), METHOD_BUFFERED; ADD/VERSION use read|write access, the rest write.
    Check 'IOCTL ADD matches CTL_CODE' ($T::IoctlAdd -eq $T::CtlCode(0x22, 0x801, 0, 3))
    Check 'IOCTL REMOVE matches CTL_CODE' ($T::IoctlRemove -eq $T::CtlCode(0x22, 0x802, 0, 2))
    Check 'IOCTL UPDATE matches CTL_CODE' ($T::IoctlUpdate -eq $T::CtlCode(0x22, 0x803, 0, 2))
    Check 'IOCTL VERSION matches CTL_CODE' ($T::IoctlVersion -eq $T::CtlCode(0x22, 0x804, 0, 3))
    Check 'REMOVE index is 16-bit big-endian' ((($T::RemovePayload(1)) -join ',') -eq '0,1' -and (($T::RemovePayload(0x0102)) -join ',') -eq '1,2')
    Check 'ping interval is under the 100 ms limit' ($T::PingMs -gt 0 -and $T::PingMs -lt 100)
    Check 'monitor count is readable' ($T::MonitorCount() -ge 1)
    # Mouse lock area: real screens only, never a box that also covers a virtual screen.
    function Scr($x, $y, $w, $h, $v) { [pscustomobject]@{ Bounds = [pscustomobject]@{ X = $x; Y = $y; Width = $w; Height = $h }; Virtual = $v } }
    $hr = Get-HomeRect @((Scr 0 0 1920 1080 $false), (Scr 1920 0 1920 1080 $true))
    Check 'lock area: main + virtual -> main' ($hr -and $hr.X -eq 0 -and $hr.Width -eq 1920 -and $hr.Height -eq 1080)
    $hr = Get-HomeRect @((Scr 0 0 1920 1080 $false), (Scr -1280 0 1280 1024 $false), (Scr 1920 0 1920 1080 $true))
    Check 'lock area: two real screens + virtual -> both real' ($hr -and $hr.X -eq -1280 -and $hr.Width -eq 3200 -and $hr.Height -eq 1080)
    Check 'lock area: virtual between real screens -> no lock' ($null -eq (Get-HomeRect @((Scr 0 0 1920 1080 $false), (Scr 1920 0 1920 1080 $true), (Scr 3840 0 1920 1080 $false))))
    Check 'lock area: no virtual screen -> no lock' ($null -eq (Get-HomeRect @((Scr 0 0 1920 1080 $false), (Scr 1920 0 1920 1080 $false))))
    # Holders and idle stop.
    $alive = { param($p) $p -in 10, 30 }
    Check 'holders: only live pids, no duplicates, no zero' ((@(Get-LiveHolders @(10, 20, 30, 10, 0) $alive) -join ',') -eq '10,30')
    Check 'idle: live holder keeps the screen' (-not (Test-KeeperIdle 1 0 (60 * 60000) 10))
    Check 'idle: stops after IdleMinutes without holders' (Test-KeeperIdle 0 0 (10 * 60000) 10)
    Check 'idle: not before IdleMinutes' (-not (Test-KeeperIdle 0 0 (9 * 60000) 10))
    # Screen ids and which screen a session gets.
    $savedCc = $env:CLAUDE_CODE_SESSION_ID
    $env:MODO_EQUIPO_SCREEN_ID = ''; $env:CLAUDE_CODE_SESSION_ID = ''
    Check 'id: default when none is given' ((Resolve-ScreenId '') -eq 'default')
    $env:CLAUDE_CODE_SESSION_ID = '99A1426C-0f0d-4ce1-81f3-b92a627e9f91'
    Check 'id: each Claude Code session gets its own id' ((Resolve-ScreenId '') -eq 'cc-99a1426c')
    $env:MODO_EQUIPO_SCREEN_ID = 'QA-1'
    Check 'id: MODO_EQUIPO_SCREEN_ID wins, lower case' ((Resolve-ScreenId '') -eq 'qa-1')
    Check 'id: -ScreenId wins over both' ((Resolve-ScreenId 'dev') -eq 'dev')
    $env:MODO_EQUIPO_SCREEN_ID = ''; $env:CLAUDE_CODE_SESSION_ID = $savedCc
    $bad = $false; try { Resolve-ScreenId 'a b/c' | Out-Null } catch { $bad = $true }
    Check 'id: rejects spaces and slashes' $bad
    function S2($n, $p, $v) { [pscustomobject]@{ Name = $n; Primary = $p; Virtual = $v } }
    $scr = @((S2 'D1' $true $false), (S2 'D5' $false $true), (S2 'D6' $false $true))
    $orph = @([pscustomobject]@{ index = 3; device = 'D6'; id = 'qa' })
    $k = Select-ScreenFor 'qa' $scr @() $orph
    Check 'pick: an id gets its own display back after a keeper restart' ($k.Kind -eq 'orphan' -and $k.Device -eq 'D6' -and $k.Index -eq 3)
    $k = Select-ScreenFor 'default' $scr @() $orph
    Check 'pick: default takes a second screen that is already there' ($k.Kind -eq 'adopt' -and $k.Device -eq 'D5')
    $k = Select-ScreenFor 'dev' $scr @('D5') @()
    Check 'pick: another id never shares a screen, it gets a new display' ($k.Kind -eq 'add')
    $k = Select-ScreenFor 'dev' $scr @('D5') $orph
    Check 'pick: an unclaimed display the keeper owns is reused' ($k.Kind -eq 'orphan' -and $k.Device -eq 'D6')
    $k = Select-ScreenFor 'qa' $scr @('D6') $orph
    Check 'pick: a display another session holds is not handed out' ($k.Kind -eq 'add')
    $k = Select-ScreenFor 'qa' @((S2 'D1' $true $false)) @() $orph
    Check 'pick: a display that went away is not handed out' ($k.Kind -eq 'add')
    $hr = Get-HomeRect @((Scr 0 0 1920 1080 $false), (Scr 1920 0 1920 1080 $true), (Scr 3840 0 1920 1080 $true), (Scr 5760 0 1920 1080 $true))
    Check 'lock area: main + three virtual -> main' ($hr -and $hr.X -eq 0 -and $hr.Width -eq 1920)
    Check 'display limit follows parsec-vdd.h' ($script:MaxDisplays -eq 8)
    $d = [ModoEquipo.CursorLock]::Desktop()
    Check 'desktop rectangle is readable' (($d.Right - $d.Left) -gt 0 -and ($d.Bottom - $d.Top) -gt 0)
    # Driver state is informational: a machine without the driver still passes.
    $path = $T::FindDevicePath()
    if ($path) {
        try { $v = $T::Open(); "INFO driver found, version $($v.Version())"; $v.Dispose() }
        catch { "INFO driver found but not openable: $($_.Exception.Message)" }
    } elseif (Test-DriverOffline) { 'INFO driver installed but offline (crashed): restart the device or reboot' }
    else { 'INFO driver not installed' }
    if ($fail) { "$fail check(s) failed"; exit 1 } else { 'All checks passed'; exit 0 }
}
