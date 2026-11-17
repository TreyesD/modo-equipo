"""Launch a program so that none of its windows is ever shown on the primary screen.

Usage:
    py -3 launch_offscreen.py [--screen N|auto] [--timeout S] [--keep-watch S] [--trace] -- <exe> [args...]
    py -3 launch_offscreen.py --list

Windows only, Python 3 standard library only (ctypes). On other systems it prints
{"ok":false,"reason":"windows-only"} and exits with code 3.

Method (zero-flash):
1. CreateProcess with CREATE_SUSPENDED and STARTF_USESHOWWINDOW / SW_SHOWMINNOACTIVE, so the first
   show of the main window is minimized and inactive.
2. Before ResumeThread, out-of-context WinEvent hooks (EVENT_OBJECT_SHOW, EVENT_OBJECT_LOCATIONCHANGE)
   follow every top-level window of the process and of its child processes.
3. First show minimized: SetWindowPlacement puts the restored position on the second screen and
   restores it with SW_SHOWNOACTIVATE, so it goes from minimized straight to the second screen.
4. Guard: any visible window that touches the primary screen is made transparent (WS_EX_LAYERED,
   alpha 0), moved to the second screen without activation, then made opaque again.

It never sends input, never takes focus, never injects code and never changes display settings.
It does not wait for the program to end: the program keeps running after this script exits.

Exit codes: 0 placed on the second screen; 1 launch failed; 2 usage error; 3 not Windows;
4 no second screen (program started the normal way); 5 a window was still on the primary
screen at the end (rule broken: stop that test and fix it).
"""
import argparse
import json
import subprocess
import sys
import time

EXIT_OK, EXIT_LAUNCH_FAILED, EXIT_USAGE, EXIT_NOT_WINDOWS, EXIT_NO_SECOND_SCREEN, EXIT_ON_PRIMARY = 0, 1, 2, 3, 4, 5
IS_WINDOWS = sys.platform == "win32"


# ---------------------------------------------------------------- portable logic (tested on every OS)

class UsageError(Exception):
    pass


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def parse_args(argv):
    """Parse `[options] -- <exe> [args...]`. Everything after the first `--` is the command, untouched."""
    if "--" in argv:
        i = argv.index("--")
        opts, command = argv[:i], argv[i + 1:]
    else:
        opts, command = argv, []
    p = _Parser(prog="launch_offscreen.py",
                description="Launch a program straight onto the second screen (Windows).")
    p.add_argument("--screen", default="auto",
                   help="index of a non-primary screen from --list, or 'auto' (first non-primary)")
    p.add_argument("--timeout", type=float, default=15.0, help="seconds to wait for the first window")
    p.add_argument("--keep-watch", type=float, default=10.0,
                   help="seconds to keep guarding new windows after the first one")
    p.add_argument("--trace", action="store_true", help="include every observed window event in the result")
    p.add_argument("--list", action="store_true", help="print the screens and exit")
    ns = p.parse_args(opts)
    if ns.screen != "auto":
        try:
            ns.screen = int(ns.screen)
        except ValueError:
            raise UsageError("--screen must be 'auto' or a screen index")
        if ns.screen < 0:
            raise UsageError("--screen must be 0 or more")
    if ns.timeout <= 0:
        raise UsageError("--timeout must be greater than 0")
    if ns.keep_watch < 0:
        raise UsageError("--keep-watch must be 0 or more")
    if not ns.list and not command:
        raise UsageError("missing command: use -- <exe> [args...]")
    ns.command = command
    return ns


def intersects(a, b):
    """True when rects (left, top, right, bottom) overlap by at least one pixel."""
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def choose_screen(screens, spec):
    """Pick the target screen. `auto`: first non-primary or None. An index must name a non-primary screen."""
    if spec == "auto":
        return next((s for s in screens if not s["primary"]), None)
    if spec >= len(screens):
        raise UsageError(f"--screen {spec}: there are only {len(screens)} screens")
    if screens[spec]["primary"]:
        raise UsageError(f"--screen {spec} is the primary screen")
    return screens[spec]


def placement_rect(width, height, work):
    """Window rect of the given size (clamped to the work area) centered on the work area."""
    ww, wh = work[2] - work[0], work[3] - work[1]
    w, h = max(1, min(width, ww)), max(1, min(height, wh))
    left, top = work[0] + (ww - w) // 2, work[1] + (wh - h) // 2
    return (left, top, left + w, top + h)


def emit(result):
    print(json.dumps(result, separators=(",", ":")), flush=True)


# ---------------------------------------------------------------- Windows-only part

if IS_WINDOWS:
    import ctypes
    from ctypes import wintypes

    U = ctypes.WinDLL("user32", use_last_error=True)
    K = ctypes.WinDLL("kernel32", use_last_error=True)
    try:
        DWM = ctypes.WinDLL("dwmapi")
    except OSError:
        DWM = None

    EVENT_OBJECT_SHOW, EVENT_OBJECT_LOCATIONCHANGE = 0x8002, 0x800B
    WINEVENT_OUTOFCONTEXT, WINEVENT_SKIPOWNPROCESS = 0x0, 0x2
    GWL_EXSTYLE, WS_EX_LAYERED, WS_EX_TOOLWINDOW, LWA_ALPHA = -20, 0x80000, 0x80, 0x2
    SWP_NOZORDER, SWP_NOACTIVATE = 0x4, 0x10
    STARTF_USESHOWWINDOW, SW_SHOWMINNOACTIVE, SW_SHOWNOACTIVATE = 0x1, 7, 4
    CREATE_SUSPENDED, GA_ROOT, MONITORINFOF_PRIMARY = 0x4, 2, 1
    DWMWA_EXTENDED_FRAME_BOUNDS, TH32CS_SNAPPROCESS = 9, 0x2
    QS_ALLINPUT, PM_REMOVE, WAIT_OBJECT_0 = 0x4FF, 0x1, 0

    class STARTUPINFO(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("lpReserved", wintypes.LPWSTR), ("lpDesktop", wintypes.LPWSTR),
                    ("lpTitle", wintypes.LPWSTR), ("dwX", wintypes.DWORD), ("dwY", wintypes.DWORD),
                    ("dwXSize", wintypes.DWORD), ("dwYSize", wintypes.DWORD),
                    ("dwXCountChars", wintypes.DWORD), ("dwYCountChars", wintypes.DWORD),
                    ("dwFillAttribute", wintypes.DWORD), ("dwFlags", wintypes.DWORD),
                    ("wShowWindow", wintypes.WORD), ("cbReserved2", wintypes.WORD),
                    ("lpReserved2", ctypes.c_void_p), ("hStdInput", wintypes.HANDLE),
                    ("hStdOutput", wintypes.HANDLE), ("hStdError", wintypes.HANDLE)]

    class PROCESS_INFORMATION(ctypes.Structure):
        _fields_ = [("hProcess", wintypes.HANDLE), ("hThread", wintypes.HANDLE),
                    ("dwProcessId", wintypes.DWORD), ("dwThreadId", wintypes.DWORD)]

    class WINDOWPLACEMENT(ctypes.Structure):
        _fields_ = [("length", wintypes.UINT), ("flags", wintypes.UINT), ("showCmd", wintypes.UINT),
                    ("ptMinPosition", wintypes.POINT), ("ptMaxPosition", wintypes.POINT),
                    ("rcNormalPosition", wintypes.RECT)]

    class MONITORINFOEXW(ctypes.Structure):
        _fields_ = [("cbSize", wintypes.DWORD), ("rcMonitor", wintypes.RECT), ("rcWork", wintypes.RECT),
                    ("dwFlags", wintypes.DWORD), ("szDevice", wintypes.WCHAR * 32)]

    class PROCESSENTRY32W(ctypes.Structure):
        _fields_ = [("dwSize", wintypes.DWORD), ("cntUsage", wintypes.DWORD),
                    ("th32ProcessID", wintypes.DWORD), ("th32DefaultHeapID", ctypes.c_size_t),
                    ("th32ModuleID", wintypes.DWORD), ("cntThreads", wintypes.DWORD),
                    ("th32ParentProcessID", wintypes.DWORD), ("pcPriClassBase", ctypes.c_long),
                    ("dwFlags", wintypes.DWORD), ("szExeFile", wintypes.WCHAR * 260)]

    WINEVENTPROC = ctypes.WINFUNCTYPE(None, wintypes.HANDLE, wintypes.DWORD, wintypes.HWND, wintypes.LONG,
                                      wintypes.LONG, wintypes.DWORD, wintypes.DWORD)
    MONITORENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HMONITOR, wintypes.HDC,
                                         ctypes.POINTER(wintypes.RECT), wintypes.LPARAM)
    WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

    U.SetWinEventHook.restype = wintypes.HANDLE
    U.SetWinEventHook.argtypes = [wintypes.UINT, wintypes.UINT, wintypes.HMODULE, WINEVENTPROC,
                                  wintypes.DWORD, wintypes.DWORD, wintypes.UINT]
    U.UnhookWinEvent.argtypes = [wintypes.HANDLE]
    U.GetAncestor.restype = wintypes.HWND
    U.GetAncestor.argtypes = [wintypes.HWND, wintypes.UINT]
    U.GetWindowLongW.restype = ctypes.c_long
    U.GetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int]
    U.SetWindowLongW.argtypes = [wintypes.HWND, ctypes.c_int, ctypes.c_long]
    U.SetLayeredWindowAttributes.argtypes = [wintypes.HWND, wintypes.DWORD, wintypes.BYTE, wintypes.DWORD]
    U.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                               ctypes.c_int, wintypes.UINT]
    U.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
    U.GetWindowPlacement.argtypes = [wintypes.HWND, ctypes.POINTER(WINDOWPLACEMENT)]
    U.SetWindowPlacement.argtypes = [wintypes.HWND, ctypes.POINTER(WINDOWPLACEMENT)]
    U.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    U.IsWindowVisible.argtypes = [wintypes.HWND]
    U.IsIconic.argtypes = [wintypes.HWND]
    U.IsZoomed.argtypes = [wintypes.HWND]
    U.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
    U.GetMonitorInfoW.argtypes = [wintypes.HMONITOR, ctypes.POINTER(MONITORINFOEXW)]
    U.EnumDisplayMonitors.argtypes = [wintypes.HDC, ctypes.POINTER(wintypes.RECT), MONITORENUMPROC,
                                      wintypes.LPARAM]
    U.EnumWindows.argtypes = [WNDENUMPROC, wintypes.LPARAM]
    U.MsgWaitForMultipleObjects.argtypes = [wintypes.DWORD, ctypes.c_void_p, wintypes.BOOL, wintypes.DWORD,
                                            wintypes.DWORD]
    U.PeekMessageW.argtypes = [ctypes.POINTER(wintypes.MSG), wintypes.HWND, wintypes.UINT, wintypes.UINT,
                               wintypes.UINT]
    K.CreateProcessW.argtypes = [wintypes.LPCWSTR, wintypes.LPWSTR, ctypes.c_void_p, ctypes.c_void_p,
                                 wintypes.BOOL, wintypes.DWORD, ctypes.c_void_p, wintypes.LPCWSTR,
                                 ctypes.POINTER(STARTUPINFO), ctypes.POINTER(PROCESS_INFORMATION)]
    K.ResumeThread.argtypes = [wintypes.HANDLE]
    K.CloseHandle.argtypes = [wintypes.HANDLE]
    K.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    K.CreateToolhelp32Snapshot.restype = wintypes.HANDLE
    K.CreateToolhelp32Snapshot.argtypes = [wintypes.DWORD, wintypes.DWORD]
    K.Process32FirstW.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
    K.Process32NextW.argtypes = [wintypes.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]


def set_dpi_aware():
    """Per-monitor DPI awareness so every rect is in physical pixels. Best effort."""
    try:
        if U.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4)):  # PER_MONITOR_AWARE_V2
            return
    except (AttributeError, OSError):
        pass
    try:
        ctypes.WinDLL("shcore").SetProcessDpiAwareness(2)
        return
    except (AttributeError, OSError):
        pass
    try:
        U.SetProcessDPIAware()
    except (AttributeError, OSError):
        pass


def list_screens():
    screens = []

    def cb(hmon, hdc, rect, data):
        mi = MONITORINFOEXW()
        mi.cbSize = ctypes.sizeof(mi)
        if U.GetMonitorInfoW(hmon, ctypes.byref(mi)):
            m, w = mi.rcMonitor, mi.rcWork
            screens.append({"index": len(screens), "name": mi.szDevice,
                            "primary": bool(mi.dwFlags & MONITORINFOF_PRIMARY),
                            "rect": [m.left, m.top, m.right, m.bottom],
                            "work": [w.left, w.top, w.right, w.bottom]})
        return True

    U.EnumDisplayMonitors(None, None, MONITORENUMPROC(cb), 0)
    return screens


def window_rect(hwnd):
    """Visible frame of a window (without the invisible DWM resize borders when available)."""
    r = wintypes.RECT()
    if DWM is not None and DWM.DwmGetWindowAttribute(wintypes.HWND(hwnd), DWMWA_EXTENDED_FRAME_BOUNDS,
                                                     ctypes.byref(r), ctypes.sizeof(r)) == 0:
        return (r.left, r.top, r.right, r.bottom)
    U.GetWindowRect(hwnd, ctypes.byref(r))
    return (r.left, r.top, r.right, r.bottom)


def window_pid(hwnd):
    pid = wintypes.DWORD()
    U.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return pid.value


def top_level_windows(pids):
    """Visible top-level windows that belong to any of `pids`."""
    found = []

    def cb(h, _):
        if U.IsWindowVisible(h) and window_pid(h) in pids:
            found.append(h)
        return True

    U.EnumWindows(WNDENUMPROC(cb), 0)
    return found


def parent_map():
    parents = {}
    snap = K.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if not snap or snap == wintypes.HANDLE(-1).value:
        return parents
    try:
        e = PROCESSENTRY32W()
        e.dwSize = ctypes.sizeof(e)
        ok = K.Process32FirstW(snap, ctypes.byref(e))
        while ok:
            parents[e.th32ProcessID] = e.th32ParentProcessID
            ok = K.Process32NextW(snap, ctypes.byref(e))
    finally:
        K.CloseHandle(snap)
    return parents


class Watcher:
    """Follows the windows of one process tree and keeps them off the primary screen."""

    def __init__(self, root_pid, target, primary, trace):
        self.pids, self.others = {root_pid}, set()
        self.target, self.primary = target, primary
        self.trace = [] if trace else None
        self.seen, self.windows, self.guard_hits = set(), [], []
        self.t0 = time.monotonic()
        self.first_window_at = None
        self._proc = WINEVENTPROC(self._cb)  # keep a reference: ctypes callbacks must outlive the hooks
        flags = WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS
        self.hooks = [U.SetWinEventHook(ev, ev, None, self._proc, 0, 0, flags)
                      for ev in (EVENT_OBJECT_SHOW, EVENT_OBJECT_LOCATIONCHANGE)]

    def _ours(self, pid):
        if pid in self.pids:
            return True
        if pid in self.others:
            return False
        parents, p, chain = parent_map(), pid, []
        while p and p not in chain and len(chain) < 64:
            chain.append(p)
            p = parents.get(p)
            if p in self.pids:
                self.pids.update(chain)
                return True
        self.others.add(pid)
        return False

    def _t(self):
        return round(time.monotonic() - self.t0, 4)

    def _cb(self, hook, ev, h, obj, child, tid, ms):
        try:
            if obj != 0 or child != 0 or not h or U.GetAncestor(h, GA_ROOT) != h:
                return
            if not self._ours(window_pid(h)):
                return
            self._handle(ev, h)
        except Exception:  # a callback must never raise into Windows
            pass

    def _handle(self, ev, h):
        visible, minimized = bool(U.IsWindowVisible(h)), bool(U.IsIconic(h))
        rect = window_rect(h)
        if self.trace is not None:
            self.trace.append({"t": self._t(), "ev": "show" if ev == EVENT_OBJECT_SHOW else "loc", "hwnd": h,
                               "rect": list(rect), "visible": visible, "minimized": minimized})
        if not visible:
            return
        if h not in self.seen:
            self.seen.add(h)
            if self.first_window_at is None:
                self.first_window_at = time.monotonic()
            if minimized:
                self._restore_on_target(h)
                return
            if not intersects(rect, self.primary["rect"]):
                self.windows.append({"hwnd": h, "how": "already-off-primary", "rect": list(rect)})
                return
        if not minimized and rect[2] > rect[0] and intersects(rect, self.primary["rect"]):
            self._guard(h, rect)

    def _restore_on_target(self, h):
        wp = WINDOWPLACEMENT()
        wp.length = ctypes.sizeof(wp)
        U.GetWindowPlacement(h, ctypes.byref(wp))
        n = wp.rcNormalPosition
        l, t, r, b = placement_rect(n.right - n.left, n.bottom - n.top, self.target["work"])
        if not U.GetWindowLongW(h, GWL_EXSTYLE) & WS_EX_TOOLWINDOW:
            # rcNormalPosition is in workspace coordinates (relative to the primary work area).
            dx, dy = self.primary["work"][0], self.primary["work"][1]
            l, t, r, b = l - dx, t - dy, r - dx, b - dy
        wp.rcNormalPosition = wintypes.RECT(l, t, r, b)
        wp.showCmd, wp.flags = SW_SHOWNOACTIVATE, 0
        U.SetWindowPlacement(h, ctypes.byref(wp))
        self.windows.append({"hwnd": h, "how": "restored", "rect": list(window_rect(h))})

    def _guard(self, h, rect):
        ex = U.GetWindowLongW(h, GWL_EXSTYLE)
        hide = not ex & WS_EX_LAYERED  # never touch the alpha of a window that manages its own layering
        if hide:
            U.SetWindowLongW(h, GWL_EXSTYLE, ex | WS_EX_LAYERED)
            U.SetLayeredWindowAttributes(h, 0, 0, LWA_ALPHA)
        if U.IsZoomed(h):
            U.ShowWindow(h, SW_SHOWNOACTIVATE)
            rect = window_rect(h)
        l, t, r, b = placement_rect(rect[2] - rect[0], rect[3] - rect[1], self.target["work"])
        U.SetWindowPos(h, None, l, t, r - l, b - t, SWP_NOZORDER | SWP_NOACTIVATE)
        if hide:
            U.SetLayeredWindowAttributes(h, 0, 255, LWA_ALPHA)
            U.SetWindowLongW(h, GWL_EXSTYLE, ex)
        after = list(window_rect(h))
        self.guard_hits.append({"t": self._t(), "hwnd": h, "before": list(rect), "after": after})
        self.windows.append({"hwnd": h, "how": "moved", "rect": after})

    def pump(self, ms):
        U.MsgWaitForMultipleObjects(0, None, False, ms, QS_ALLINPUT)
        msg = wintypes.MSG()
        while U.PeekMessageW(ctypes.byref(msg), None, 0, 0, PM_REMOVE):
            U.TranslateMessage(ctypes.byref(msg))
            U.DispatchMessageW(ctypes.byref(msg))

    def close(self):
        for hook in self.hooks:
            if hook:
                U.UnhookWinEvent(hook)


def run_windows(ns):
    set_dpi_aware()
    screens = list_screens()
    if ns.list:
        emit({"ok": True, "screens": screens})
        return EXIT_OK
    target = choose_screen(screens, ns.screen)
    if target is None:
        try:
            proc = subprocess.Popen(ns.command)
        except OSError as e:
            emit({"ok": False, "reason": "launch-failed", "error": str(e), "secondScreen": False})
            return EXIT_LAUNCH_FAILED
        emit({"ok": True, "secondScreen": False, "pid": proc.pid,
              "note": "no second screen: started the normal way", "screens": screens})
        return EXIT_NO_SECOND_SCREEN
    primary = next(s for s in screens if s["primary"])

    si = STARTUPINFO()
    si.cb = ctypes.sizeof(si)
    si.dwFlags, si.wShowWindow = STARTF_USESHOWWINDOW, SW_SHOWMINNOACTIVE
    pi = PROCESS_INFORMATION()
    cmdline = ctypes.create_unicode_buffer(subprocess.list2cmdline(ns.command))
    if not K.CreateProcessW(None, cmdline, None, None, False, CREATE_SUSPENDED, None, None,
                            ctypes.byref(si), ctypes.byref(pi)):
        err = ctypes.get_last_error()
        emit({"ok": False, "reason": "launch-failed", "error": ctypes.FormatError(err).strip(),
              "winerror": err, "secondScreen": True})
        return EXIT_LAUNCH_FAILED

    watcher = Watcher(pi.dwProcessId, target, primary, ns.trace)
    K.ResumeThread(pi.hThread)
    K.CloseHandle(pi.hThread)
    start = time.monotonic()
    exited = timed_out = False
    try:
        while True:
            watcher.pump(50)
            now = time.monotonic()
            if watcher.first_window_at is None:
                if now - start >= ns.timeout:
                    timed_out = True
                    break
                if K.WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0 and len(watcher.pids) == 1:
                    exited = True
                    break
            elif now - watcher.first_window_at >= ns.keep_watch:
                break
        exited = exited or K.WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0
    finally:
        watcher.close()
        K.CloseHandle(pi.hProcess)

    # Final check of every visible window of the process tree.
    open_windows = [{"hwnd": h, "rect": list(window_rect(h))}
                    for h in top_level_windows(watcher.pids) if not U.IsIconic(h)]
    on_primary = [w for w in open_windows if intersects(w["rect"], primary["rect"])]
    result = {"ok": not on_primary, "secondScreen": True, "pid": pi.dwProcessId,
              "pids": sorted(watcher.pids), "screen": target, "windows": watcher.windows,
              "guardHits": watcher.guard_hits, "openWindows": open_windows, "onPrimaryAtEnd": on_primary,
              "timedOut": timed_out, "exited": exited, "elapsed": round(time.monotonic() - start, 2)}
    if watcher.trace is not None:
        result["trace"] = watcher.trace
    emit(result)
    return EXIT_ON_PRIMARY if on_primary else EXIT_OK


def main(argv=None, platform=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        ns = parse_args(argv)
    except UsageError as e:
        emit({"ok": False, "reason": "usage", "error": str(e)})
        return EXIT_USAGE
    if (platform or sys.platform) != "win32":
        emit({"ok": False, "reason": "windows-only",
              "note": "no zero-flash launcher on this system: run the program the normal way or headless"})
        return EXIT_NOT_WINDOWS
    try:
        return run_windows(ns)
    except UsageError as e:
        emit({"ok": False, "reason": "usage", "error": str(e)})
        return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
