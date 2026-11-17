# Global test rule block

The skill appends the block below, exactly as written (from the opening marker to the closing marker), to the user's `~/.claude/CLAUDE.md`, only after the user says yes. Bump the version number in both markers whenever the text changes, so installed copies can be detected as outdated.

```markdown
<!-- modo-equipo:global-rule v2 -->
## Tests that leave the user's screen, mouse and keyboard alone (modo-equipo)

Applies to every session, with or without team mode.

- Never move the real cursor, send real keystrokes or take window focus to run tests or automation, and never ask the user to stop using their mouse or keyboard.
- Pick an input method that does not touch the user's devices, by what the test needs: the test runner itself; Playwright or the built-in browser for web pages; UI Automation or messages to a window handle for Windows apps; a virtual pad with background input for emulators and games.
- When a second screen exists, every window a test opens goes there, always, whatever the number of windows, and never appears on the main screen, not even briefly: place it before it shows (app position settings, launch options, saved layout), check all its windows, and stop the test if one reaches the main screen. Tests that open no window can run anywhere.
- If a task truly needs a real cursor (for example computer-use on a native app), use an isolated cursor if one is set up; otherwise say so first, give the expected duration and wait for the user's OK.
- Details and helper scripts are in the modo-equipo skill folder (plugin: `~/.claude/plugins/cache/*/modo-equipo/*/skills/modo-equipo/`; manual install: `~/.claude/skills/modo-equipo/`): `references/virtual-pad.md`, `references/own-cursor.md`, `references/second-screen.md`, `scripts/second-screen/`, `scripts/virtual-pad/`.
<!-- /modo-equipo:global-rule -->
```
