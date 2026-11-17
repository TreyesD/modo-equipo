"""Print the <!-- gentle-ai:* --> blocks of a CLAUDE.md file; with --hash print their sha256."""
import hashlib, re, sys

def blocks(text):
    out, depth = [], 0
    for line in text.splitlines():
        opening = re.match(r'\s*<!-- gentle-ai:[\w-]+ -->\s*$', line)
        closing = re.match(r'\s*<!-- /gentle-ai:[\w-]+ -->\s*$', line)
        if opening:
            depth += 1
        if depth > 0:
            out.append(line)
        if closing and depth > 0:
            depth -= 1
    return "\n".join(out) + "\n"

if __name__ == "__main__":
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        result = blocks(f.read())
    if "--hash" in sys.argv:
        print(hashlib.sha256(result.encode("utf-8")).hexdigest())
    else:
        sys.stdout.buffer.write(result.encode("utf-8"))
