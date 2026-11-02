#!/bin/bash
set -euo pipefail
if [ "$#" -ne 1 ]; then echo "Usage: $0 artifact.app-or-dmg" >&2; exit 2; fi
: "$NOTARY_KEY_ID" "$NOTARY_ISSUER" "$NOTARY_KEY_PATH"
artifact="$1"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if [[ "$artifact" == *.app ]]; then
  ditto -c -k --keepParent "$artifact" "$tmp/OpenJBL.zip"
  submission="$tmp/OpenJBL.zip"
else
  submission="$artifact"
fi
xcrun notarytool submit "$submission" --key "$NOTARY_KEY_PATH" \
  --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait \
  --output-format json > "$tmp/result.json"
python3 - "$tmp/result.json" <<'PY'
import json, sys
with open(sys.argv[1]) as file:
    result = json.load(file)
if result.get("status") != "Accepted":
    sys.exit("Notarization was not accepted; inspect the notary log.")
PY
xcrun stapler staple "$artifact"
xcrun stapler validate "$artifact"
