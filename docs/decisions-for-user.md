# Decisions waiting for the user

## Push of the viewer releases (1.3.21 to 1.3.24)

Everything is committed on `main` and the viewer copy in `~/.claude/modo-equipo/viewer` is already updated. Nothing is pushed: a push needs the owner's own go-ahead.

```bash
git -C "E:/Claude/modo-equipo" push origin main
```

## If the viewer misbehaves

- The GPU picture falls back to the old Magnification picture by itself and says so in the window title (`[basic scaling]`).
- To force the old picture: set `MODO_EQUIPO_NO_GPU=1`.
- To go back to the previous scripts: copy each `*.prev.ps1` in `~/.claude/modo-equipo/viewer` over the file without `.prev` (the GPU module `screen-gpu.ps1` can stay; the old viewer ignores it).

## Open item

- The Parsec display driver crashed once during a long add/remove stress run and had to be restarted (`pnputil /restart-device "ROOT\DISPLAY\0000"` as administrator, or a reboot). The stress and Dolphin interference tests were not completed after that; the stress test now defaults to 10 cycles.
