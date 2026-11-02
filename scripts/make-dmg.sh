#!/bin/bash
set -euo pipefail
if [ "$#" -ne 2 ]; then echo "Usage: $0 OpenJBL.app output.dmg" >&2; exit 2; fi
if [ ! -d "$1/Contents" ] || [ -e "$2" ]; then
  echo "Input must be an app and output must not exist." >&2; exit 1
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ditto "$1" "$tmp/OpenJBL.app"
ln -s /Applications "$tmp/Applications"
# No probe, developer captures or signing files are ever copied to staging.
hdiutil create -volname OpenJBL -srcfolder "$tmp" -format UDZO -ov "$2"
