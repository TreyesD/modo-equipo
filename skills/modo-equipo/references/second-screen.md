# Second screen for tests (Windows)

Goal: run the test suites on a second display so the user keeps working on the main screen. The skill only needs Windows 10/11 and a display that Windows reports as a non-primary screen. A real monitor works; so does a virtual one.

**Safety contract.** The skill never downloads, installs or runs third-party files by itself. Every step below that downloads, installs a driver or starts a downloaded program is done by the user. If the agent downloads anything for the user, it first names the file, source and size and waits for an explicit yes.

## Option A - a physical monitor

Connect it, press `Win+P`, choose **Extend** (Ampliar). Done.

## Option B - virtual monitor with ParsecVDisplay (verified on Windows 10 Pro)

This is a small tray app that adds and removes virtual displays. It needs the Parsec virtual display driver.

1. Get the release: https://github.com/nomi-san/parsec-vdd/releases (asset `ParsecVDisplay-vX.Y-portable.zip`, under 1 MB). Extract it into its own empty folder.
2. Check the driver. In PowerShell: `Get-PnpDevice -Class Display | Where-Object FriendlyName -match Parsec`. If a "Parsec Virtual Display Adapter" with status OK is listed, skip to step 4.
3. If the driver is missing: the zip contains `parsec-vdd-<version>.exe`, the driver installer signed by Parsec Cloud, Inc. Verify with `Get-AuthenticodeSignature .\parsec-vdd-*.exe` (status must be Valid), then run it as administrator.
4. Start `ParsecVDisplay.exe`. It is **not code-signed** (normal for this open-source project): SmartScreen shows a warning; use "More info" then "Run anyway" only if you accept that. In the tray icon choose **Add display**.
5. If Windows does not extend automatically: `Win+P`, **Extend**.
6. Verify: run `scripts/second-screen/detect.ps1`; it must print `"secondScreen":true`.

Notes:
- Only the driver (steps 2-3) is required by the skill: `open-viewer.ps1` talks to it directly and needs no `ParsecVDisplay.exe` window. The app is kept as a fallback and for adding displays by hand.
- A virtual display lives only while something keeps pinging the driver (the viewer launcher or `ParsecVDisplay.exe`). When that stops, the display disappears; the skill then falls back to the normal test flow.
- The app can start with Windows (setting inside the app).

## Option C - Virtual Display Driver (alternative, driver-level)

Project: https://github.com/VirtualDrivers/Virtual-Display-Driver (assets named `VirtualDisplayDriver-*.Driver.Only.zip`). Its package is signed (SignPath Foundation). Installing it needs administrator rights and creating the virtual monitor follows that project's own README. This path was **not** completed in testing; prefer Option B.

## What the skill does with it

- `scripts/second-screen/detect.ps1`: prints JSON with `secondScreen` true or false.
- `scripts/second-screen/launch-on-second-screen.ps1 -Root <project>`: opens the test runner window on the second screen. Exit code 2 and `NO_SECOND_SCREEN` when there is none.
- `scripts/second-screen/launch_offscreen.py -- <exe> [args...]`: starts any windowed program so none of its windows is ever shown on the main screen (minimized + suspended start, WinEvent hook, placement before the first visible frame, transparent-move guard). Prints one JSON line; exit 0 placed, 1 launch failed, 2 usage, 3 not Windows, 4 no second screen (started normally), 5 a window stayed on the main screen. Apps that restore their own saved geometry may need an app-specific pre-set (for example Dolphin's `Qt.ini` window geometry).
- `scripts/second-screen/run-tests.ps1`: detects suites (package.json `test` script, pytest `tests/`, `go.mod`, `Cargo.toml`), runs them in order, writes `~/.claude/modo-equipo/tests-last.json` (`status` running|done, result per suite) and `tests-last.log`. Override detection with `<project>/.modo-equipo-tests.json`: `[{"name":"api","dir":"services/api","cmd":"npm test"}]`.
- `scripts/second-screen/screen-viewer.ps1`: borderless window on the main screen that mirrors the second one live through the Magnification API (GPU, ~60 fps, real cursor). Moving over the image drives the real cursor there; a floating toolbar offers always-on-top (small window only), pointer, mute, mouse lock, full screen, hide, minimize and close. While a virtual screen exists the viewer keeps the real cursor on the real screens (`ClipCursor`), lifting the clip while a mouse button is held (window drags) and in direct mode; it never overrides a clip another program set, and a hidden watchdog process releases it if the viewer dies.
- `scripts/second-screen/open-viewer.ps1`: one-click entry point. When there is no second screen it adds one silently through the installed Parsec Virtual Display Driver (`parsec-vdd.ps1`, no app window), opens the viewer, and removes that screen when the viewer closes. Only if the driver cannot be used does it fall back to starting `ParsecVDisplay.exe` and pressing ADD DISPLAY, with a message that says why.
- `scripts/second-screen/parsec-vdd.ps1`: direct driver control (SetupAPI interface lookup, add/remove/keep-alive IOCTLs from nomi-san/parsec-vdd `parsec-vdd.h`, BSD-2-Clause, credited in NOTICE). Dot-source it for `[ModoEquipo.ParsecVdd]`; `-SelfTest` checks the constants and never adds a display. `install-desktop-shortcut.ps1` creates a desktop shortcut for it; the user runs that once.

## Troubleshooting

- `MISSING TOOL: <x>` in a suite: that suite's tool (bun, python, pytest, go, cargo) is not installed. Install it or define the suite in `.modo-equipo-tests.json`.
- `No module named pytest`: `python -m pip install pytest`.
- Viewer shows black: the second screen may simply be empty; open a window there.
- Window appears on the wrong place after the display is re-added: run the launcher again.
