"""Install, check or remove the modo-equipo global test rule block in a CLAUDE.md file.

Usage:
  python global_rule.py status  [--file PATH]   prints: missing | current vN | outdated vN (latest vM)
  python global_rule.py install [--file PATH]   adds the block, or replaces an older version
  python global_rule.py remove  [--file PATH]   deletes the block

PATH defaults to ~/.claude/CLAUDE.md. The block text comes from references/global-rule.md
next to this script's folder. Only the marked block is ever touched; the rest of the file
is kept byte for byte. Run install only after the user said yes.
"""
import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REFERENCE = os.path.join(HERE, "..", "references", "global-rule.md")
BLOCK_RE = re.compile(r"<!-- modo-equipo:global-rule v(\d+) -->.*?<!-- /modo-equipo:global-rule -->", re.S)


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
    folder = os.path.dirname(path)
    if folder:
        os.makedirs(folder, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def status(text, latest):
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
    elif args.action == "install":
        if BLOCK_RE.search(text):
            text = BLOCK_RE.sub(lambda _: block, text, count=1)
        else:
            separator = "" if not text or text.endswith(newline * 2) else (newline if text.endswith(newline) else newline * 2)
            text = text + separator + block + newline
        write(args.file, text)
        print(status(text, latest))
    elif args.action == "remove":
        match = BLOCK_RE.search(text)
        new = text
        if match:
            # Drop the block plus the line break that followed it; leave everything else as is.
            end = match.end()
            if text.startswith(newline, end):
                end += len(newline)
            new = text[:match.start()] + text[end:]
        if new != text:
            write(args.file, new)
        print(status(new, latest))


if __name__ == "__main__":
    main()
