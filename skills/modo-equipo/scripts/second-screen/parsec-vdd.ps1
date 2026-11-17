param([switch]$SelfTest)
# Talks to the installed Parsec Virtual Display Driver directly, the same way the
# ParsecVDisplay app does, so a virtual second screen can be added with no app window.
# Dot-source it (". .\parsec-vdd.ps1") to get the [ModoEquipo.ParsecVdd] type, or run it with
# -SelfTest to check the IOCTL constants and the driver state without adding any display.
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
    # Driver state is informational: a machine without the driver still passes.
    $path = $T::FindDevicePath()
    if ($path) {
        try { $v = $T::Open(); "INFO driver found, version $($v.Version())"; $v.Dispose() }
        catch { "INFO driver found but not openable: $($_.Exception.Message)" }
    } else { 'INFO driver not installed' }
    if ($fail) { "$fail check(s) failed"; exit 1 } else { 'All checks passed'; exit 0 }
}
