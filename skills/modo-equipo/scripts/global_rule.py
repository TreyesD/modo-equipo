"""Install, check or remove the modo-equipo global test rule block in a CLAUDE.md file.

Usage:
  python global_rule.py status  [--file PATH]   prints: missing | current vN | outdated vN (latest vM) | broken: ...
  python global_rule.py install [--file PATH]   adds the block, or replaces an older version
  python global_rule.py remove  [--file PATH]   deletes the block

PATH defaults to ~/.claude/CLAUDE.md. The block text comes from references/global-rule.md
next to this script's folder. Only the marked block is ever touched; the rest of the file
is kept byte for byte, and files are written atomically. Exit code 2 means the markers are
damaged and nothing was changed. Run install only after the user said yes.
"""
import argparse
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REFERENCE = os.path.join(HERE, "..", "references", "global-rule.md")
BLOCK_RE = re.compile(r"<!-- modo-equipo:global-rule v(\d+) -->.*?<!-- /modo-equipo:global-rule -->", re.S)
OPEN_RE = re.compile(r"<!-- modo-equipo:global-rule v\d+ -->")
CLOSE = "<!-- /modo-equipo:global-rule -->"


def reference_block():
    with open(REFERENCE, encoding="utf-8") as f:
        match = BLOCK_RE.search(f.read())
    if not match:
        sys.exit("global-rule.md has no marked block")
    return match.group(0), int(match.group(1))


def read(path):
    if not os.path.exists(path):
        return ""
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()


def write(path, text):
    """Write atomically: a temp file in the same folder, then replace. The original file is
    never truncated, so an interruption cannot leave a half-written CLAUDE.md."""
    folder = os.path.dirname(os.path.abspath(path))
    os.makedirs(folder, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".CLAUDE.md.", suffix=".tmp", dir=folder)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise


def broken(text):
    """True when the markers do not pair up (for example a hand-deleted closing marker)."""
    opens = len(OPEN_RE.findall(text))
    closes = text.count(CLOSE)
    return opens != closes or opens != len(BLOCK_RE.findall(text)) or opens > 1


def status(text, latest):
    if broken(text):
        return "broken: unmatched or repeated modo-equipo:global-rule markers; fix the file by hand"
    match = BLOCK_RE.search(text)
    if not match:
        return "missing"
    version = int(match.group(1))
    if version >= latest:
        return f"current v{version}"
    return f"outdated v{version} (latest v{latest})"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("action", choices=["status", "install", "remove"])
    parser.add_argument("--file", default=os.path.join(os.path.expanduser("~"), ".claude", "CLAUDE.md"))
    args = parser.parse_args()

    block, latest = reference_block()
    text = read(args.file)
    newline = "\r\n" if "\r\n" in text else "\n"
    block = block.replace("\n", newline)

    if args.action == "status":
        print(status(text, latest))
        return
    if broken(text):
        print(status(text, latest))
        sys.exit(2)  # never guess where a damaged block ends

    if args.action == "install":
        if BLOCK_RE.search(text):
            text = BLOCK_RE.sub(lambda _: block, text, count=1)
        else:
            # Leave exactly one blank line between the existing text and the block.
            if not text:
                separator = ""
            elif text.endswith(newline):
                separator = newline
            else:
                separator = newline * 2
            text = text + separator + block + newline
        write(args.file, text)
        print(status(text, latest))
    elif args.action == "remove":
        match = BLOCK_RE.search(text)
        new = text
        if match:
            start, end = match.start(), match.end()
            if text.startswith(newline, end):
                end += len(newline)
            before, after = text[:start], text[end:]
            # A block at the end of the file was preceded by the blank line install added: drop it too.
            if not after and before.endswith(newline * 2):
                before = before[:-len(newline)]
            new = before + after
        if new != text:
            write(args.file, new)
        print(status(new, latest))


if __name__ == "__main__":
    main()
