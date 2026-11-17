# Virtual pad for emulator tests (no real keyboard, no focus)

Goal: drive an emulator from tests without touching the user's keyboard, mouse or window focus, so the user keeps working while the tests run (ideally on the second screen).

Tool: `scripts/virtual-pad/dsu_server.py`, a small DSU (cemuhook protocol) pad server in pure Python. No driver, no install, localhost only. Dolphin has a DSU client built in; other emulators with DSU input (for example Cemu, Citra, Ryujinx, RPCS3) can use it the same way.

Verified on Windows 10 with Dolphin 2609b and a GameCube game: with Dolphin unfocused on the second screen, 20 of 20 D-pad presses and the START presses were registered.

## 1. Start the pad server

```
python dsu_server.py <log-file>
```

- Pad slot 0, served on `127.0.0.1:26760`.
- Commands go to UDP `127.0.0.1:26761` as plain text:
  - `press <Input> <ms>`: hold an input, then release it.
  - `hold <Input>` / `release <Input>`.
  - `stick <lx> <ly>`: left stick bytes 0..255, 128 = center.
  - `quit`.
- Inputs: `Cross Circle Square Triangle L1 R1 L2 R2 PadN PadS PadE PadW Options Share`.
- Example from Python: `socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b"press Cross 120", ("127.0.0.1", 26761))`.

## 2. Give the emulator its own test profile (Dolphin)

Never change the user's own emulator settings. Launch Dolphin with a separate user folder: `Dolphin.exe -u <test-user-dir> -b -e <game>`. Put these files in `<test-user-dir>/Config/`:

`Dolphin.ini`
```
[Analytics]
Enabled = False
PermissionAsked = True
[Core]
SIDevice0 = 6
[Display]
Fullscreen = False
[Input]
BackgroundInput = True
[Interface]
ConfirmStop = False
```

`DSUClient.ini`
```
[Server]
Enabled = True
Entries = Test:127.0.0.1:26760;
```

`GCPadNew.ini` (map the GameCube pad to the virtual pad only; no keyboard device anywhere)
```
[GCPad1]
Device = DSUClient/0/Test
Buttons/A = Cross
Buttons/B = Circle
Buttons/X = Square
Buttons/Y = Triangle
Buttons/Z = R1
Buttons/Start = Options
Main Stick/Up = `Left Y-`
Main Stick/Down = `Left Y+`
Main Stick/Left = `Left X-`
Main Stick/Right = `Left X+`
Triggers/L = L2
Triggers/R = R2
D-Pad/Up = `Pad N`
D-Pad/Down = `Pad S`
D-Pad/Left = `Pad W`
D-Pad/Right = `Pad E`
```

`Hotkeys.ini` (no hotkeys: with background input on, keyboard hotkeys would fire while the user types elsewhere)
```
[Hotkeys]
Device = DSUClient/0/Test
```

The device name after `DSUClient/0/` is the description in `Entries` (`Test` here).

## 3. Rules learned in testing

- **Focus at launch**: Dolphin started directly from a script (for example Python `subprocess.Popen`) took focus once at launch; started through `powershell Start-Process` it did not. Launch without activation and check that the user's window is still in front.
- **Window position**: `RenderWindowXPos/YPos` were ignored. After launch, move the render window to the second screen with `SetWindowPos(hwnd, 0, x, y, w, h, SWP_NOACTIVATE | SWP_NOZORDER)`.
- **Savestates**: hotkeys are off, so load states at boot with the emulator's command line (Dolphin: `-s <file>`), not with F-keys.
- **Screenshots**: capture the render window's client area with all screens enabled (Pillow: `ImageGrab.grab(rect, all_screens=True)`); it works on the second screen while unfocused.
- **Stopping**: stop only the test instance, found by its command line (the `-u <test-user-dir>` path). Never kill every emulator process: another session may be using its own.
- **Mixed display scaling**: run any script that reads window or screen coordinates as per-monitor DPI aware (`SetProcessDpiAwarenessContext(-4)`), or positions on a second screen with a different scale come out wrong.
- **Stick direction**: verify `Left Y-` = up once per game; the DSU field is stored inverted.
