"""Cross-platform tests for the modo-equipo plugin (stdlib only).

Run from the repository root:  python -m unittest discover -s tests -v
"""
import binascii
import contextlib
import importlib.util
import io
import json
import os
import re
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILL = os.path.join(ROOT, "skills", "modo-equipo")
SCRIPTS = os.path.join(SKILL, "scripts")


def run(script, *args):
    return subprocess.run([sys.executable, os.path.join(SCRIPTS, script), *args],
                          capture_output=True, text=True, encoding="utf-8", timeout=60)


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class PluginStructure(unittest.TestCase):
    def test_manifests_are_valid_and_names_match(self):
        with open(os.path.join(ROOT, ".claude-plugin", "plugin.json"), encoding="utf-8") as f:
            plugin = json.load(f)
        with open(os.path.join(ROOT, ".claude-plugin", "marketplace.json"), encoding="utf-8") as f:
            market = json.load(f)
        self.assertEqual(plugin["name"], "modo-equipo")
        self.assertRegex(plugin["version"], r"^\d+\.\d+\.\d+$")
        self.assertEqual([p["name"] for p in market["plugins"]], ["modo-equipo"])

    def test_skill_frontmatter_and_referenced_files_exist(self):
        with open(os.path.join(SKILL, "SKILL.md"), encoding="utf-8") as f:
            text = f.read()
        self.assertTrue(text.startswith("---\nname: modo-equipo\ndescription: "))
        refs = set(re.findall(r"\$\{CLAUDE_SKILL_DIR\}/([\w./-]+)", text))
        self.assertTrue(refs)
        missing = [r for r in sorted(refs) if not os.path.exists(os.path.join(SKILL, r.rstrip("/.")))]
        self.assertEqual(missing, [])

    def test_no_windows_drive_paths_in_portable_files(self):
        for name in ("SKILL.md", os.path.join("references", "global-rule.md"),
                     os.path.join("references", "virtual-pad.md")):
            with open(os.path.join(SKILL, name), encoding="utf-8") as f:
                self.assertNotRegex(f.read(), r"\b[A-Z]:[\\/](Users|Claude|descargas)", name)


class Docs(unittest.TestCase):
    @staticmethod
    def slug(heading):
        # GitHub-style anchor: lowercase, drop punctuation except - and _, spaces to -.
        text = heading.strip().lower()
        text = re.sub(r"[^\w\- ]", "", text)
        return text.replace(" ", "-")

    def test_relative_links_and_anchors_resolve(self):
        files = [os.path.join(ROOT, "README.md")]
        docs = os.path.join(ROOT, "docs")
        files += [os.path.join(docs, n) for n in sorted(os.listdir(docs)) if n.endswith(".md")]
        self.assertGreaterEqual(len(files), 8)
        broken = []
        for path in files:
            with open(path, encoding="utf-8") as f:
                text = f.read()
            for target in re.findall(r"\]\(([^)\s]+)\)", text):
                if re.match(r"^[a-z]+:", target):
                    continue  # external URL
                file_part, _, anchor = target.partition("#")
                dest = os.path.normpath(os.path.join(os.path.dirname(path), file_part)) if file_part else path
                if not os.path.exists(dest):
                    broken.append(f"{os.path.relpath(path, ROOT)} -> {target}")
                    continue
                if anchor and dest.endswith(".md"):
                    with open(dest, encoding="utf-8") as f:
                        slugs = {self.slug(h) for h in re.findall(r"^#+ (.+)$", f.read(), re.M)}
                    if anchor not in slugs:
                        broken.append(f"{os.path.relpath(path, ROOT)} -> {target} (anchor)")
        self.assertEqual(broken, [])


class SessionTokens(unittest.TestCase):
    def test_dedupes_repeated_lines_by_message_id(self):
        lines = [
            {"type": "user", "message": {"content": "hi"}},
            {"type": "assistant", "message": {"id": "m1", "usage": {"input_tokens": 1, "output_tokens": 2}}},
            {"type": "assistant", "message": {"id": "m1", "usage": {"input_tokens": 1, "output_tokens": 5}}},
            {"type": "assistant", "message": {"id": "m2", "usage": {"cache_read_input_tokens": 10}}},
        ]
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "s.jsonl")
            with open(path, "w", encoding="utf-8") as f:
                f.write("\n".join(json.dumps(x) for x in lines) + "\nnot json\n")
            out = run("session_tokens.py", path)
        self.assertEqual(out.returncode, 0, out.stderr)
        result = json.loads(out.stdout)
        self.assertEqual(result["responses"], 2)
        self.assertEqual(result["output_tokens"], 5)  # last line of m1 wins, not 2 + 5
        self.assertEqual(result["total"], 1 + 5 + 10)


class GentleBlocks(unittest.TestCase):
    TEXT = ("## Mine\nkeep out\n<!-- gentle-ai:a -->\nA\n<!-- gentle-ai:b -->\nB\n<!-- /gentle-ai:b -->\n"
            "<!-- /gentle-ai:a -->\nbetween\n<!-- gentle-ai:c -->\nC\n<!-- /gentle-ai:c -->\ntail\n")

    def test_extracts_only_marked_blocks_and_hash_is_stable(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "CLAUDE.md")
            with open(path, "w", encoding="utf-8") as f:
                f.write(self.TEXT)
            blocks = run("gentle_blocks.py", path)
            h1 = run("gentle_blocks.py", path, "--hash").stdout.strip()
            h2 = run("gentle_blocks.py", path, "--hash").stdout.strip()
        self.assertEqual(blocks.returncode, 0, blocks.stderr)
        self.assertIn("B", blocks.stdout)
        self.assertIn("C", blocks.stdout)
        for outside in ("keep out", "between", "tail"):
            self.assertNotIn(outside, blocks.stdout)
        self.assertRegex(h1, r"^[0-9a-f]{64}$")
        self.assertEqual(h1, h2)


class GlobalRule(unittest.TestCase):
    ORIGINAL = "# Rules\n\nkeep me\n\n\n\nthree blank lines above stay\n<!-- gentle-ai:x -->\nG\n<!-- /gentle-ai:x -->\n"

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.tmp.name, "CLAUDE.md")

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, text, newline=""):
        with open(self.path, "w", encoding="utf-8", newline=newline) as f:
            f.write(text)

    def read(self):
        with open(self.path, encoding="utf-8", newline="") as f:
            return f.read()

    def rule(self, action):
        out = run("global_rule.py", action, "--file", self.path)
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout.strip()

    def test_install_is_idempotent_and_remove_restores_the_file(self):
        self.write(self.ORIGINAL)
        self.assertEqual(self.rule("status"), "missing")
        self.assertRegex(self.rule("install"), r"^current v\d+$")
        once = self.read()
        self.assertTrue(once.startswith(self.ORIGINAL))
        self.assertGreater(once.index("<!-- modo-equipo:global-rule"), once.index("<!-- /gentle-ai:x -->"))
        self.rule("install")
        self.assertEqual(self.read(), once)
        self.assertEqual(once.count("<!-- modo-equipo:global-rule"), 1)
        self.assertEqual(self.rule("remove"), "missing")
        self.assertEqual(self.read(), self.ORIGINAL)  # byte for byte
        self.assertEqual([n for n in os.listdir(self.tmp.name) if n != "CLAUDE.md"], [])  # no temp files left

    def test_symlinked_file_is_written_through_and_keeps_the_link(self):
        real = os.path.join(self.tmp.name, "dotfiles-CLAUDE.md")
        with open(real, "w", encoding="utf-8", newline="") as f:
            f.write(self.ORIGINAL)
        try:
            os.symlink(real, self.path)
        except (OSError, NotImplementedError):
            self.skipTest("symlinks not available here (Windows without the right privilege)")
        self.rule("install")
        self.assertTrue(os.path.islink(self.path))
        with open(real, encoding="utf-8", newline="") as f:
            self.assertIn("<!-- modo-equipo:global-rule v", f.read())
        self.rule("remove")
        self.assertTrue(os.path.islink(self.path))
        with open(real, encoding="utf-8", newline="") as f:
            self.assertEqual(f.read(), self.ORIGINAL)

    @unittest.skipIf(os.name == "nt", "POSIX permissions")
    def test_file_permissions_are_kept(self):
        self.write(self.ORIGINAL)
        os.chmod(self.path, 0o644)
        self.rule("install")
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o644)

    def test_damaged_markers_are_never_rewritten(self):
        damaged = "x\n<!-- modo-equipo:global-rule v1 -->\nclosing marker deleted by hand\n"
        self.write(damaged)
        self.assertTrue(self.rule("status").startswith("broken"))
        for action in ("install", "remove"):
            out = run("global_rule.py", action, "--file", self.path)
            self.assertEqual(out.returncode, 2, action)
            self.assertEqual(self.read(), damaged, action)

    def test_outdated_block_is_replaced_in_place(self):
        old = "<!-- modo-equipo:global-rule v0 -->\nold text\n<!-- /modo-equipo:global-rule -->"
        self.write("before\n" + old + "\nafter\n")
        self.assertTrue(self.rule("status").startswith("outdated v0"))
        self.rule("install")
        text = self.read()
        self.assertNotIn("old text", text)
        self.assertTrue(text.startswith("before\n<!-- modo-equipo:global-rule v"))
        self.assertTrue(text.endswith("<!-- /modo-equipo:global-rule -->\nafter\n"))

    def test_keeps_crlf_line_endings(self):
        self.write("a\r\nb\r\n")
        self.rule("install")
        text = self.read()
        self.assertNotIn("\n", text.replace("\r\n", ""))

    def test_creates_missing_file(self):
        self.path = os.path.join(self.tmp.name, "new", "CLAUDE.md")
        self.assertEqual(self.rule("status"), "missing")
        self.assertRegex(self.rule("install"), r"^current v\d+$")


class DsuServer(unittest.TestCase):
    @staticmethod
    def request(msg_type, payload=b""):
        body = struct.pack("<I", msg_type) + payload
        header = b"DSUC" + struct.pack("<HHII", 1001, len(body), 0, 7)
        crc = binascii.crc32(header + body) & 0xFFFFFFFF
        return b"DSUC" + struct.pack("<HHII", 1001, len(body), crc, 7) + body

    @staticmethod
    def crc_ok(packet):
        crc = struct.unpack_from("<I", packet, 8)[0]
        return binascii.crc32(packet[:8] + b"\0\0\0\0" + packet[12:]) & 0xFFFFFFFF == crc

    def start(self, tmp, name):
        port, ctrl = free_port(), free_port()
        log = os.path.join(tmp, name + ".log")
        proc = subprocess.Popen([sys.executable, os.path.join(SCRIPTS, "virtual-pad", "dsu_server.py"), log,
                                 "--port", str(port), "--ctrl-port", str(ctrl)])
        for _ in range(50):
            if os.path.exists(log):
                break
            time.sleep(0.1)
        return proc, port, ctrl

    def test_two_servers_on_custom_ports_answer_valid_packets(self):
        with tempfile.TemporaryDirectory() as tmp:
            servers = [self.start(tmp, "a"), self.start(tmp, "b")]
            try:
                for proc, port, ctrl in servers:
                    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    self.addCleanup(s.close)
                    s.settimeout(3)
                    s.sendto(self.request(0x100001, struct.pack("<i", 1) + b"\0"), ("127.0.0.1", port))
                    info = s.recv(256)
                    self.assertEqual(len(info), 32)
                    self.assertTrue(self.crc_ok(info))
                    self.assertEqual(info[21], 2)  # slot 0 connected
                    s.sendto(self.request(0x100002, bytes([1, 0]) + b"\0" * 6), ("127.0.0.1", port))
                    data = s.recv(256)
                    self.assertEqual(len(data), 100)
                    self.assertTrue(self.crc_ok(data))
                    # header 16 + message type 4 + pad info 11 + (active, counter, buttons) 9
                    # + sticks 4 + analog D-pad 4 and Square 1 -> the Cross analog byte
                    cross = 16 + 4 + 11 + 9 + 4 + 5
                    self.assertEqual(data[cross], 0)
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as c:
                        c.sendto(b"press Cross 500", ("127.0.0.1", ctrl))
                    deadline = time.time() + 2
                    pressed = False
                    while time.time() < deadline and not pressed:
                        pressed = s.recv(256)[cross] == 255
                    self.assertTrue(pressed, "Cross press not reflected in pad data")
                    s.close()
            finally:
                for proc, port, ctrl in servers:
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as c:
                        c.sendto(b"quit", ("127.0.0.1", ctrl))
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.kill()


def load_offscreen():
    path = os.path.join(SCRIPTS, "second-screen", "launch_offscreen.py")
    spec = importlib.util.spec_from_file_location("launch_offscreen", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class LaunchOffscreen(unittest.TestCase):
    """Portable checks of launch_offscreen.py; they pass on every OS."""

    @classmethod
    def setUpClass(cls):
        cls.m = load_offscreen()

    def call(self, argv, platform):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            code = self.m.main(argv, platform=platform)
        lines = buf.getvalue().splitlines()
        self.assertEqual(len(lines), 1, lines)  # always exactly one JSON line
        return code, json.loads(lines[0])

    def test_parses_options_and_keeps_the_command_untouched(self):
        ns = self.m.parse_args(["--screen", "2", "--timeout", "5", "--keep-watch", "0", "--",
                                "app.exe", "--screen", "auto", "--"])
        self.assertEqual((ns.screen, ns.timeout, ns.keep_watch), (2, 5.0, 0.0))
        self.assertEqual(ns.command, ["app.exe", "--screen", "auto", "--"])
        ns = self.m.parse_args(["--", "notepad.exe"])
        self.assertEqual((ns.screen, ns.timeout, ns.keep_watch, ns.trace), ("auto", 15.0, 10.0, False))
        self.assertTrue(self.m.parse_args(["--list"]).list)

    def test_bad_arguments_are_usage_errors_with_exit_2(self):
        for argv in ([], ["--screen", "x", "--", "a"], ["--screen", "-1", "--", "a"],
                     ["--timeout", "0", "--", "a"], ["--keep-watch", "-1", "--", "a"], ["--bogus", "--", "a"]):
            code, out = self.call(argv, "win32")
            self.assertEqual(code, 2, argv)
            self.assertEqual((out["ok"], out["reason"]), (False, "usage"), argv)

    def test_refuses_on_non_windows_with_exit_3(self):
        for platform in ("darwin", "linux"):
            code, out = self.call(["--", "app"], platform)
            self.assertEqual(code, 3)
            self.assertEqual((out["ok"], out["reason"]), (False, "windows-only"))

    @unittest.skipIf(sys.platform == "win32", "real non-Windows run")
    def test_runs_as_a_script_on_this_system(self):
        out = run(os.path.join("second-screen", "launch_offscreen.py"), "--", "true")
        self.assertEqual(out.returncode, 3, out.stderr)
        self.assertEqual(json.loads(out.stdout)["reason"], "windows-only")

    def test_keeper_command_and_ensure(self):
        cmd = self.m.keeper_command(holder=42, script="k.ps1")
        self.assertEqual(cmd[-5:], ["-File", "k.ps1", "-Ensure", "-HolderPid", "42"])
        self.assertNotIn("-HolderPid", self.m.keeper_command(script="k.ps1"))
        calls = []

        class Out:
            stdout = 'noise\n{"ok": true, "secondScreen": true, "keeper": "started"}\n'

        def fake_run(cmd, **kw):
            calls.append(cmd)
            return Out()
        answer = self.m.ensure_screen(holder=7, run=fake_run, environ={}, exists=lambda p: True)
        self.assertEqual(answer["keeper"], "started")
        self.assertIn("7", calls[0])
        # Test switch and a missing keeper script: nothing is run.
        self.assertIsNone(self.m.ensure_screen(run=fake_run, environ={"MODO_EQUIPO_NO_SECOND_SCREEN": "1"}, exists=lambda p: True))
        self.assertIsNone(self.m.ensure_screen(run=fake_run, environ={}, exists=lambda p: False))
        self.assertEqual(len(calls), 1)

        def broken(cmd, **kw):
            raise OSError("no powershell")
        self.assertIsNone(self.m.ensure_screen(run=broken, environ={}, exists=lambda p: True))
        self.assertTrue(self.m.parse_args(["--no-ensure", "--", "app"]).no_ensure)

    def test_session_screen_id(self):
        cmd = self.m.keeper_command(holder=42, script="k.ps1", screen_id="qa")
        self.assertEqual(cmd[-7:], ["-File", "k.ps1", "-Ensure", "-ScreenId", "qa", "-HolderPid", "42"])
        self.assertNotIn("-ScreenId", self.m.keeper_command(script="k.ps1"))   # keeper reads the env var
        calls = []

        class Out:
            stdout = '{"ok": true, "secondScreen": true, "keeper": "running", "id": "qa", "screen": "DISPLAY7"}\n'

        def fake_run(cmd, **kw):
            calls.append(cmd)
            return Out()
        answer = self.m.ensure_screen(run=fake_run, environ={}, exists=lambda p: True, screen_id="qa")
        self.assertEqual(answer["screen"], "DISPLAY7")
        self.assertIn("qa", calls[0])
        self.assertEqual(self.m.parse_args(["--screen-id", "qa", "--", "app"]).screen_id, "qa")
        self.assertIsNone(self.m.parse_args(["--", "app"]).screen_id)
        screens = [{"name": "DISPLAY1", "primary": True}, {"name": "DISPLAY7", "primary": False}]
        self.assertIs(self.m.screen_by_name(screens, "display7"), screens[1])
        self.assertIsNone(self.m.screen_by_name(screens, "DISPLAY9"))
        self.assertIsNone(self.m.screen_by_name(screens, None))

    def test_screen_choice(self):
        screens = [{"primary": True}, {"primary": False, "id": "a"}, {"primary": False, "id": "b"}]
        self.assertEqual(self.m.choose_screen(screens, "auto")["id"], "a")
        self.assertEqual(self.m.choose_screen(screens, 2)["id"], "b")
        self.assertIsNone(self.m.choose_screen(screens[:1], "auto"))
        for bad in (0, 3):
            with self.assertRaises(self.m.UsageError):
                self.m.choose_screen(screens, bad)

    def test_placement_is_centered_and_clamped_to_the_work_area(self):
        work = (1920, 0, 3840, 1040)
        self.assertEqual(self.m.placement_rect(800, 600, work), (2480, 220, 3280, 820))
        self.assertEqual(self.m.placement_rect(5000, 5000, work), work)
        self.assertTrue(self.m.intersects((0, 0, 10, 10), (9, 9, 20, 20)))
        self.assertFalse(self.m.intersects((0, 0, 1920, 1080), (1920, 0, 3840, 1080)))  # edge only


def _second_screen_present():
    if sys.platform != "win32":
        return False
    out = run(os.path.join("second-screen", "launch_offscreen.py"), "--list")
    return out.returncode == 0 and any(not s["primary"] for s in json.loads(out.stdout)["screens"])


@unittest.skipUnless(_second_screen_present(), "needs Windows with a second screen")
class LaunchOffscreenLive(unittest.TestCase):
    """Opens notepad.exe on the second screen. Never shown on the primary, no input, no focus."""

    NOTEPAD_KEY = r"Software\Microsoft\Notepad"

    def notepad_settings(self):
        import winreg
        values = {}
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, self.NOTEPAD_KEY) as k:
                i = 0
                while True:
                    try:
                        name, data, kind = winreg.EnumValue(k, i)
                    except OSError:
                        return values
                    values[name] = (data, kind)
                    i += 1
        except FileNotFoundError:
            return None

    def restore_notepad_settings(self, saved):
        # Notepad saves its window position on close; put the user's values back.
        import winreg
        if saved is None:
            with contextlib.suppress(OSError):
                winreg.DeleteKey(winreg.HKEY_CURRENT_USER, self.NOTEPAD_KEY)
            return
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, self.NOTEPAD_KEY) as k:
            for name in set(self.notepad_settings() or {}) - set(saved):
                winreg.DeleteValue(k, name)
            for name, (data, kind) in saved.items():
                winreg.SetValueEx(k, name, 0, kind, data)

    def test_notepad_never_touches_the_primary_screen(self):
        m = load_offscreen()
        m.set_dpi_aware()
        primary = next(s for s in m.list_screens() if s["primary"])["rect"]
        saved = self.notepad_settings()
        self.addCleanup(self.restore_notepad_settings, saved)
        out = run(os.path.join("second-screen", "launch_offscreen.py"), "--timeout", "10", "--keep-watch", "3",
                  "--trace", "--", "notepad.exe")
        result = json.loads(out.stdout)
        pids = set(result.get("pids", []))
        self.addCleanup(self.close_windows, m, pids)
        if not result.get("windows"):
            self.skipTest("notepad.exe opened no window of its own process tree here (packaged Notepad?)")
        self.assertEqual(out.returncode, 0, out.stdout)
        self.assertEqual(result["guardHits"], [])
        shown = [e for e in result["trace"] if e["visible"] and not e["minimized"]]
        self.assertTrue(shown)
        self.assertEqual([e for e in shown if m.intersects(e["rect"], primary)], [])
        for h in m.top_level_windows(pids):
            if not m.U.IsIconic(h):
                self.assertFalse(m.intersects(m.window_rect(h), primary))

    @staticmethod
    def close_windows(m, pids):
        WM_CLOSE = 0x10
        for h in m.top_level_windows(pids):
            m.U.PostMessageW(h, WM_CLOSE, 0, 0)  # a message, not input: no focus change
        deadline = time.time() + 5
        while time.time() < deadline and m.top_level_windows(pids):
            time.sleep(0.2)
        for pid in pids:  # last resort if a window refused to close
            subprocess.run(["taskkill", "/PID", str(pid), "/F"], capture_output=True)


class ParsecVirtualDisplay(unittest.TestCase):
    """Direct driver control used by open-viewer.ps1 (no ParsecVDisplay window)."""
    DIR = os.path.join(SCRIPTS, "second-screen")

    def test_viewer_files_are_installed_together(self):
        with open(os.path.join(self.DIR, "install-desktop-shortcut.ps1"), encoding="utf-8") as f:
            install = f.read()
        with open(os.path.join(self.DIR, "open-viewer.ps1"), encoding="utf-8") as f:
            launcher = f.read()
        self.assertIn("parsec-vdd.ps1", install)   # the shortcut copy must include the module
        self.assertIn("parsec-vdd.ps1", launcher)
        self.assertIn("'-Ensure', '-HolderPid', $PID", launcher)   # the viewer holds its session's screen
        self.assertIn("$viewerArgs['Screen'] = $r.screen", launcher)  # and shows that screen
        for name in ("launch-on-second-screen.ps1", "detect.ps1"):
            with open(os.path.join(self.DIR, name), encoding="utf-8") as f:
                text = f.read()
            self.assertIn("'-Ensure'", text, name)     # launchers ask the keeper for a screen
            self.assertIn("'-ScreenId'", text, name)   # for their own session id

    @unittest.skipUnless(sys.platform == "win32", "Windows PowerShell only")
    def test_self_test_checks_ioctls_without_adding_a_display(self):
        out = subprocess.run(
            ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
             os.path.join(self.DIR, "parsec-vdd.ps1"), "-SelfTest"],
            capture_output=True, text=True, timeout=120)
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("All checks passed", out.stdout)
        self.assertNotIn("FAIL", out.stdout)


if __name__ == "__main__":
    unittest.main()
