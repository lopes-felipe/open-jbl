#!/bin/bash
set -euo pipefail
if [ "$#" -ne 1 ]; then echo "Usage: $0 OpenJBL.app" >&2; exit 2; fi
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
codesign --verify --deep --strict "$1"
if ! codesign -d --entitlements - --xml "$1" > "$tmp" 2>/dev/null; then
  # Older macOS codesign has no --xml. The legacy colon form emits XML.
  codesign -d --entitlements :- "$1" > "$tmp" 2>/dev/null
fi
python3 - "$tmp" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as file:
    entitlements = plistlib.load(file)
required = {
    "com.apple.security.app-sandbox",
    "com.apple.security.device.bluetooth",
    "com.apple.security.files.user-selected.read-write"
}
assert all(entitlements.get(key) is True for key in required), "Missing required entitlement"
allowed = required | {"com.apple.security.get-task-allow", "com.apple.application-identifier", "com.apple.developer.team-identifier"}
assert set(entitlements) <= allowed, "Unexpected entitlements"
print("Signature and entitlements passed.")
PY
