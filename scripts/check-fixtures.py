#!/usr/bin/env python3
"""Local hygiene check; never displays denylist values or fixture payloads."""
import argparse
import pathlib
import re
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--require-denylist", action="store_true")
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
fixtures = sorted((root / "Tests/JBLKitTests/Fixtures").rglob("*.race.txt"))
deny = root / "research/denylist.txt"
if args.require_denylist and fixtures and not deny.is_file():
    sys.exit("Private research/denylist.txt is required before committing captures.")
secrets = []
if deny.is_file():
    for line in deny.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            secrets.append(line)

failed = False
for path in fixtures:
    text = path.read_text()
    compact = re.sub(r"[\s:\-]", "", text).lower()
    for secret in secrets:
        if secret.lower() in text.lower():
            print(f"{path.name}: private identifier matched", file=sys.stderr)
            failed = True
        normalized = re.sub(r"[\s:\-]", "", secret)
        if len(normalized) % 2 == 0 and re.fullmatch(r"[0-9a-fA-F]+", normalized):
            raw = bytes.fromhex(normalized)
        else:
            raw = secret.encode()
        if raw.hex() in compact or raw[::-1].hex() in compact:
            print(f"{path.name}: private byte sequence matched", file=sys.stderr)
            failed = True
    for header in ("provenance", "app", "firmware", "hardware"):
        if not re.search(rf"^# {header}: \S", text, re.MULTILINE):
            print(f"{path.name}: missing {header} metadata", file=sys.stderr)
            failed = True
    directions = set()
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        try:
            if not re.fullmatch(r"[<>] (?:[0-9a-fA-F]{2})(?: [0-9a-fA-F]{2})*", line):
                raise ValueError()
            data = bytes.fromhex(line[2:])
            if len(data) < 6 or data[0] != 5 or data[1] not in (0x5A, 0x5B, 0x5C, 0x5D):
                raise ValueError()
            if int.from_bytes(data[2:4], "little") + 4 != len(data):
                raise ValueError()
            directions.add(line[0])
        except ValueError:
            print(f"{path.name}:{number}: invalid complete RACE fixture line", file=sys.stderr)
            failed = True
    if directions != {"<", ">"}:
        print(f"{path.name}: command and reply evidence are both required", file=sys.stderr)
        failed = True
if failed:
    sys.exit(1)
print(f"Fixture hygiene passed ({len(fixtures)} capture fixtures; synthetic tests are not evidence).")
