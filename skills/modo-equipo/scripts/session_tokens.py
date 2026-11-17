"""Sum the token usage of one Claude Code session transcript (.jsonl).

Usage: python session_tokens.py <path-to-session.jsonl>

Claude Code writes one assistant response as several transcript lines that
share the same message.id, so lines are deduplicated by message.id (the last
line wins) before summing. Prints a JSON object with the totals.
"""
import json
import sys

FIELDS = (
    "input_tokens",
    "output_tokens",
    "cache_creation_input_tokens",
    "cache_read_input_tokens",
)


def session_tokens(lines):
    by_id = {}
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") != "assistant":
            continue
        message = entry.get("message") or {}
        usage = message.get("usage")
        message_id = message.get("id")
        if not usage or not message_id:
            continue
        by_id[message_id] = usage
    totals = {field: 0 for field in FIELDS}
    for usage in by_id.values():
        for field in FIELDS:
            value = usage.get(field)
            if isinstance(value, int):
                totals[field] += value
    totals["total"] = sum(totals[field] for field in FIELDS)
    totals["responses"] = len(by_id)
    return totals


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: python session_tokens.py <path-to-session.jsonl>")
    with open(sys.argv[1], encoding="utf-8") as transcript:
        result = session_tokens(transcript)
    print(json.dumps(result))
