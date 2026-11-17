# An own cursor for the agent (Windows)

Problem: Windows has one cursor and one keyboard focus per session. A second monitor, real or virtual, does not add a second cursor. An agent that clicks or types on any screen uses the user's cursor and focus.

The options below were researched in November 2026. None of them is installed by this skill: the user decides and does every download and install. Before suggesting one, explain it in plain words and name its risks.

## Ladder, lightest first

| # | Option | Own cursor? | Own keyboard focus? | Effort | Notes |
|---|---|---|---|---|---|
| 1 | Drive the app without a cursor: UI Automation patterns (pywinauto `uia` backend, FlaUI) or a UIA-based MCP server | Not needed | Partly: keystrokes and hotkeys still need focus | Low | Works for standard Windows controls (Win32, WPF, WinForms, Qt dialogs). Not for game render surfaces. |
| 2 | Child-session seat: a hidden second session of the same user (Windows loopback Remote Desktop), for example [Anode](https://github.com/skulitom/Anode) | Yes | Yes | Low to medium | The only option found that plugs into Claude Code directly (MCP). Windows 10/11 Pro, Enterprise or Education; not Home. |
| 3 | Windows Sandbox (with `<vGPU>Enable</vGPU>` in a `.wsb` file) | Yes, inside its window | Yes | Medium | Included in Windows Pro. Disposable: tools must be set up inside it on every launch. |
| 4 | Hyper-V virtual machine with the agent inside | Yes | Yes | High | Strongest isolation, persistent. Needs a license for the guest Windows. Weak GPU support for games on Windows 10. |

Not recommended: multi-cursor tools that fake several users in one session (MouseMux is paid, and games likely still see a single focus; TeamPlayer has no official source), and patches that allow several Remote Desktop sessions on Windows 10 Pro (license and security risk).

## Option 1: drive apps without the cursor

- Prefer UI Automation patterns (Invoke, Value, Toggle, Selection) on the target control over clicks.
- Messages sent to a window handle (`PostMessage`/`SendMessage` with `WM_*`) work for many classic apps; games that read raw input or XInput ignore them.
- MCP servers found: [winauto-mcp](https://github.com/PingPong2534/winauto-mcp) says it acts through UIA patterns without moving the cursor or taking focus, with limits (no hover, hotkeys, right-click or double-click in that mode); [FlaUI-MCP](https://github.com/shanselman/FlaUI-MCP) (MIT) uses UIA patterns, and its key sending depends on focus. Avoid MCP servers whose clicks move the real cursor, for example CursorTouch Windows-MCP.
- For emulators and games, use a virtual pad instead: `virtual-pad.md`.

## Option 2: child-session seat

How it works: Windows can open one "child session" for the signed-in user through loopback Remote Desktop (`WTSEnableChildSessions`, then an RDP connection with `ConnectToChildSession`). It has its own input queue, so a cursor and focus that are not the user's. Only one child session can exist per PC. It ends when the user signs out. Source: [Microsoft, child sessions](https://learn.microsoft.com/en-us/windows/win32/termserv/child-sessions).

Anode (MIT, about 12 GitHub stars, version 0.11 in November 2026) packages this as a CLI and MCP server with screenshot, input and UIA tools inside the seat. Its own documented limits:
- Desktop isolation, not a security sandbox: the seat runs as the same user with the same files.
- One seat per PC.
- Exclusive fullscreen and protected video may not capture.
- Single-instance apps can clash with copies already open on the main desktop.
- Builds are unsigned, so SmartScreen warns.
- Setup needs administrator rights once (it enables Remote Desktop and child sessions) and can restart Remote Desktop Services.
- With PIN-only sign-in, the user must type their Windows password once.
- Virtual gamepads need HidHide to stay inside the seat.

Not verified: GPU rendering inside the seat (Remote Desktop sessions use a basic software renderer unless the policy "Use hardware graphics adapters for all Remote Desktop Services sessions" is on), and DirectX apps such as Dolphin inside it. Test before relying on it.

Because the project is young and unsigned, the user should review it and run it only if they accept that risk.

## Note on computer-use in the Claude desktop app

On Windows, computer use runs on the user's real desktop. Running it alongside the user is documented only for macOS. Treat it as "needs the user's real cursor" unless it runs inside option 2, 3 or 4.
