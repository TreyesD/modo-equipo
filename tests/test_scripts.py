"""Cross-platform tests for the modo-equipo plugin (stdlib only).

Run from the repository root:  python -m unittest discover -s tests -v
"""
import binascii
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
        self.assertEqual(self.read(), self.ORIGINAL + "\n")

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


if __name__ == "__main__":
    unittest.main()
