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
- Only the driver (steps 2-3) is required by the skill: the screen keeper (`parsec-vdd.ps1`) talks to it directly and needs no `ParsecVDisplay.exe` window. The app is kept as a fallback and for adding displays by hand.
- A virtual display lives only while something keeps pinging the driver (the screen keeper or `ParsecVDisplay.exe`). When that stops, the display disappears; the skill then falls back to the normal test flow.
- The app can start with Windows (setting inside the app).

## Option C - Virtual Display Driver (alternative, driver-level)

Project: https://github.com/VirtualDrivers/Virtual-Display-Driver (assets named `VirtualDisplayDriver-*.Driver.Only.zip`). Its package is signed (SignPath Foundation). Installing it needs administrator rights and creating the virtual monitor follows that project's own README. This path was **not** completed in testing; prefer Option B.

## What the skill does with it

- `scripts/second-screen/parsec-vdd.ps1 -Ensure [-HolderPid <pid>] | -Release | -Status`: the screen keeper. `-Ensure` starts (or reuses) one hidden background process that adds a virtual screen through the driver when there is none, keeps it while any holder process runs and for `-IdleMinutes` (10) after the last one, then removes it and exits; it prints one JSON line (exit 0 = a second screen is available). While a virtual screen exists it keeps the real cursor on the real screens (`ClipCursor`), lifting the clip while a mouse button is held (window drags) and while the viewer owns the `Local\ModoEquipo.CursorFree` mutex (direct mode); it never overrides a clip another program set, the `screen-keeper/lock-off` flag file turns it off, and a hidden watchdog releases the clip if the keeper dies. `-Release` stops it now. Driver protocol from nomi-san/parsec-vdd `parsec-vdd.h` (BSD-2-Clause, credited in NOTICE).
- `scripts/second-screen/detect.ps1`: prints JSON with `secondScreen` true or false; when there is none and the driver is installed it first runs `-Ensure` (`-NoEnsure` only looks).
- `scripts/second-screen/launch-on-second-screen.ps1 -Root <project>`: opens the test runner window on the second screen, asking the keeper for one when needed and registering the runner as a holder. Exit code 2 and `NO_SECOND_SCREEN` when there is none.
- `scripts/second-screen/launch_offscreen.py -- <exe> [args...]`: starts any windowed program so none of its windows is ever shown on the main screen (asks the keeper for a screen when there is none and registers the program as a holder; `--no-ensure` skips that; minimized + suspended start, WinEvent hook, placement before the first visible frame, transparent-move guard). Prints one JSON line; exit 0 placed, 1 launch failed, 2 usage, 3 not Windows, 4 no second screen (started normally), 5 a window stayed on the main screen. Apps that restore their own saved geometry may need an app-specific pre-set (for example Dolphin's `Qt.ini` window geometry).
- `scripts/second-screen/run-tests.ps1`: detects suites (package.json `test` script, pytest `tests/`, `go.mod`, `Cargo.toml`), runs them in order, writes `~/.claude/modo-equipo/tests-last.json` (`status` running|done, result per suite) and `tests-last.log`. Override detection with `<project>/.modo-equipo-tests.json`: `[{"name":"api","dir":"services/api","cmd":"npm test"}]`.
- `scripts/second-screen/screen-viewer.ps1`: borderless window on the main screen that mirrors the second one live through the Magnification API (GPU, ~60 fps, real cursor). Moving over the image drives the real cursor there; a toolbar pill docked at the top centre (per-pixel-alpha window, rests as a thin handle and opens when the pointer reaches it, slides along the top edge from its grip) offers always-on-top (small window only), pointer, mute, mouse lock, full screen, keep open, minimize and close. The mouse lock belongs to the screen keeper; the viewer owns the `CursorFree` mutex in direct mode and its lock button writes the keeper's flag file.
- `scripts/second-screen/open-viewer.ps1`: one-click entry point. Runs `parsec-vdd.ps1 -Ensure -HolderPid <viewer>` (no app window), so the screen stays while the viewer is open and for the keeper's idle time after it closes, then opens the viewer. Only if the keeper cannot provide a screen does it fall back to starting `ParsecVDisplay.exe` and pressing ADD DISPLAY, with a message that says why.
- `parsec-vdd.ps1` can also be dot-sourced for `[ModoEquipo.ParsecVdd]` (direct add/remove/keep-alive); `-SelfTest` checks the constants and the keeper rules and never adds a display. `install-desktop-shortcut.ps1` creates a desktop shortcut for it; the user runs that once.

## Troubleshooting

- `MISSING TOOL: <x>` in a suite: that suite's tool (bun, python, pytest, go, cargo) is not installed. Install it or define the suite in `.modo-equipo-tests.json`.
- `No module named pytest`: `python -m pip install pytest`.
- Viewer shows black: the second screen may simply be empty; open a window there.
- Window appears on the wrong place after the display is re-added: run the launcher again.
