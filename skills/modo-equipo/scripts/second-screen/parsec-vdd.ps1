param(
    [switch]$SelfTest,
    [switch]$Ensure,
    [switch]$Release,
    [switch]$Status,
    [switch]$Keep,
    [int[]]$HolderPid = @(),
    [int]$IdleMinutes = 10,
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
    public int AddDisplay() {
        int index = Io(IoctlAdd, null);
        if (index < 0) throw new InvalidOperationException("The driver refused to add a display.");
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
# Screen keeper: one hidden background process that keeps a virtual second screen for as long
# as something needs it (the viewer, a test runner, an app placed there), and keeps the mouse on
# the real screens while a virtual screen exists.
#
#   parsec-vdd.ps1 -Ensure [-HolderPid <pid>,...] [-IdleMinutes N]
#       Makes sure a second screen exists: starts the keeper (or reuses the running one), waits
#       for Windows to report the screen and prints one JSON line. Holder pids keep the screen
#       alive while those processes run; after the last holder ends (or when none was given)
#       the keeper waits IdleMinutes (default 10) and then removes the screen and exits.
#       Exit 0 = a second screen is available, 1 = it could not be provided.
#   parsec-vdd.ps1 -Release   stops the keeper now (removes its screen, frees the mouse).
#   parsec-vdd.ps1 -Status    prints the keeper state as JSON.
#   parsec-vdd.ps1 -Keep      the keeper itself (started hidden by -Ensure; not for direct use).
#
# Mouse lock: while a virtual screen exists the keeper confines the cursor (ClipCursor) to the
# real screens, so plain movement does not drift onto the virtual one. It lifts the clip while a
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

$script:KeeperDir = Join-Path $env:USERPROFILE '.claude\modo-equipo\screen-keeper'
$script:KeeperMutexName = 'Local\ModoEquipo.ScreenKeeper'
$script:KeeperStopName = 'Local\ModoEquipo.ScreenKeeper.Stop'

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

# The keeper stops after IdleMinutes with no live holder.
function Test-KeeperIdle([int]$liveCount, [double]$idleSinceMs, [double]$nowMs, [double]$idleMinutes) {
    return ($liveCount -eq 0 -and ($nowMs - $idleSinceMs) -ge $idleMinutes * 60000)
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

function Add-KeeperHolders([int[]]$pids) {
    if (-not $pids) { return }
    New-Item -ItemType Directory -Force -Path $script:KeeperDir | Out-Null
    $file = Join-Path $script:KeeperDir 'holders.txt'
    for ($i = 0; $i -lt 20; $i++) {
        try { [IO.File]::AppendAllText($file, (($pids | ForEach-Object { "$_" }) -join "`r`n") + "`r`n"); return } catch { Start-Sleep -Milliseconds 50 }
    }
}

function Read-KeeperHolders {
    $file = Join-Path $script:KeeperDir 'holders.txt'
    if (-not (Test-Path $file)) { return @() }
    try { @([IO.File]::ReadAllLines($file) | ForEach-Object { $n = 0; if ([int]::TryParse($_.Trim(), [ref]$n)) { $n } }) } catch { @() }
}

function Write-KeeperHolders([int[]]$pids) {
    $file = Join-Path $script:KeeperDir 'holders.txt'
    try { [IO.File]::WriteAllText($file, (($pids | ForEach-Object { "$_" }) -join "`r`n") + $(if ($pids) { "`r`n" } else { '' })) } catch {}
}

function Get-KeeperStatus {
    $state = $null
    $running = [bool](Test-KeeperRunning)
    $sf = Join-Path $script:KeeperDir 'keeper.json'
    if ($running -and (Test-Path $sf)) { try { $state = Get-Content $sf -Raw | ConvertFrom-Json } catch {} }
    $screens = Get-ScreenList
    [pscustomobject]@{
        keeper       = $running
        pid          = $(if ($state) { $state.pid } else { $null })
        addedScreen  = $(if ($state) { $state.added } else { $false })
        lockArea     = $(if ($state) { $state.lockArea } else { '' })
        lockOn       = -not (Test-Path (Join-Path $script:KeeperDir 'lock-off'))
        holders      = @(Get-LiveHolders (Read-KeeperHolders) { param($p) [bool](Get-Process -Id $p -ErrorAction SilentlyContinue) })
        secondScreen = [bool]@($screens | Where-Object { -not $_.Primary }).Count
        screens      = @($screens | ForEach-Object { [pscustomobject]@{ name = $_.Name; primary = $_.Primary; virtual = $_.Virtual; x = $_.Bounds.X; y = $_.Bounds.Y; width = $_.Bounds.Width; height = $_.Bounds.Height } })
    }
}

function Invoke-Ensure([int[]]$holders, [int]$idleMinutes, [int]$timeoutSeconds) {
    Add-KeeperHolders $holders
    $screens = Get-ScreenList
    $second = @($screens | Where-Object { -not $_.Primary })
    $virtual = @($second | Where-Object { $_.Virtual })
    $running = Test-KeeperRunning
    # A real second monitor and no virtual one: nothing to keep and nothing to lock.
    if ($second.Count -gt 0 -and $virtual.Count -eq 0 -and -not $running) {
        return [pscustomobject]@{ ok = $true; secondScreen = $true; keeper = 'not-needed'; screen = $second[0].Name }
    }
    $how = 'running'
    if (-not $running) {
        if ($second.Count -eq 0 -and -not [ModoEquipo.ParsecVdd]::FindDevicePath()) {
            return [pscustomobject]@{ ok = $false; secondScreen = $false; keeper = 'none'; error = 'Parsec Virtual Display Driver not installed (see references/second-screen.md, option B).' }
        }
        $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argLine = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:VddScript`" -Keep -IdleMinutes $idleMinutes"
        Start-Process -FilePath $ps -ArgumentList $argLine -WindowStyle Hidden | Out-Null
        $how = 'started'
    }
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    do {
        $second = @(Get-ScreenList | Where-Object { -not $_.Primary })
        if ($second.Count -gt 0) { return [pscustomobject]@{ ok = $true; secondScreen = $true; keeper = $how; screen = $second[0].Name } }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    $log = Join-Path $script:KeeperDir 'keeper.log'
    $last = if (Test-Path $log) { (Get-Content $log -Tail 1) } else { '' }
    return [pscustomobject]@{ ok = $false; secondScreen = $false; keeper = $how; error = "no second screen after $timeoutSeconds s. $last" }
}

function Invoke-Release {
    if (-not (Test-KeeperRunning)) { return [pscustomobject]@{ ok = $true; keeper = 'none' } }
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

function Invoke-Keeper([int]$idleMinutes) {
    New-Item -ItemType Directory -Force -Path $script:KeeperDir | Out-Null
    $log = Join-Path $script:KeeperDir 'keeper.log'
    function KLog($t) { try { Add-Content -Path $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $t" } catch {} }
    $created = $false
    $single = New-Object Threading.Mutex($true, $script:KeeperMutexName, [ref]$created)
    if (-not $created) { $single.Dispose(); return }   # another keeper already runs
    Set-Content -Path $log -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') keeper start pid=$PID idle=${idleMinutes}min"
    [void][ModoEquipo.CursorLock]::SetProcessDpiAwarenessContext([IntPtr](-4))   # physical pixels
    $stop = New-Object Threading.EventWaitHandle($false, 'ManualReset', $script:KeeperStopName)
    $clipFile = Join-Path $script:KeeperDir 'clip.txt'
    $stateFile = Join-Path $script:KeeperDir 'keeper.json'
    $offFile = Join-Path $script:KeeperDir 'lock-off'
    $lock = New-Object ModoEquipo.CursorLock
    $vdd = $null; $added = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $idleSince = 0.0
    try {
        Start-ClipWatchdog $PID $clipFile
        $lock.Start()
        while (-not $stop.WaitOne(1000)) {
            # 1. Keep a second screen while the keeper runs (re-add it if it went away).
            $screens = Get-ScreenList
            if (-not @($screens | Where-Object { -not $_.Primary }).Count -and -not $added) {
                try {
                    if (-not $vdd) { $vdd = [ModoEquipo.ParsecVdd]::Open() }
                    $i = $vdd.AddDisplay(); $added = $true
                    KLog "added virtual display index=$i"
                } catch { KLog "cannot add a display: $($_.Exception.Message)"; if (-not $vdd) { break } }
            }
            # 2. Mouse lock area.
            $h = Get-HomeRect $screens
            if ($h) { $lock.SetHome($h.X, $h.Y, $h.Width, $h.Height) } else { $lock.ClearHome() }
            $lock.Enabled = -not (Test-Path $offFile)
            try {
                if ($lock.Engaged) { Set-Content -Path $clipFile -Value $lock.HomeText } elseif (Test-Path $clipFile) { Remove-Item $clipFile }
            } catch {}
            # 3. Holders and idle time.
            $live = Get-LiveHolders (Read-KeeperHolders) { param($p) [bool](Get-Process -Id $p -ErrorAction SilentlyContinue) }
            Write-KeeperHolders $live
            if ($live.Count) { $idleSince = $clock.ElapsedMilliseconds }
            try {
                [pscustomobject]@{ pid = $PID; added = $added; holders = $live; lockArea = $lock.HomeText; lockEngaged = $lock.Engaged; updated = (Get-Date -Format s) } |
                    ConvertTo-Json -Compress | Set-Content -Path $stateFile
            } catch {}
            if (Test-KeeperIdle $live.Count $idleSince $clock.ElapsedMilliseconds $idleMinutes) { KLog "idle for $idleMinutes min: stopping"; break }
        }
        if ($stop.WaitOne(0)) { KLog 'stop requested' }
    } finally {
        $lock.Stop()
        if ($vdd) { $vdd.Dispose() }   # removes the display this keeper added
        foreach ($f in $clipFile, $stateFile) { Remove-Item $f -ErrorAction SilentlyContinue }
        KLog 'keeper stopped'
        $stop.Dispose()
        $single.ReleaseMutex(); $single.Dispose()
    }
}

if ($Ensure -or $Release -or $Status) { [void][ModoEquipo.CursorLock]::SetProcessDpiAwarenessContext([IntPtr](-4)) }
if ($Ensure) {
    $r = Invoke-Ensure $HolderPid $IdleMinutes $TimeoutSeconds
    $r | ConvertTo-Json -Compress
    exit $(if ($r.ok) { 0 } else { 1 })
}
if ($Release) { Invoke-Release | ConvertTo-Json -Compress; exit 0 }
if ($Status) { Get-KeeperStatus | ConvertTo-Json -Depth 4 -Compress; exit 0 }
if ($Keep) { Invoke-Keeper $IdleMinutes; exit 0 }

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
    $d = [ModoEquipo.CursorLock]::Desktop()
    Check 'desktop rectangle is readable' (($d.Right - $d.Left) -gt 0 -and ($d.Bottom - $d.Top) -gt 0)
    # Driver state is informational: a machine without the driver still passes.
    $path = $T::FindDevicePath()
    if ($path) {
        try { $v = $T::Open(); "INFO driver found, version $($v.Version())"; $v.Dispose() }
        catch { "INFO driver found but not openable: $($_.Exception.Message)" }
    } else { 'INFO driver not installed' }
    if ($fail) { "$fail check(s) failed"; exit 1 } else { 'All checks passed'; exit 0 }
}
