#!/bin/bash
# Open this file from Finder or run it in a normal user-launched Terminal.
# This launcher never changes privacy settings or attempts pairing/paging.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "Run this launcher in a user-launched interactive terminal, not an agent subprocess." >&2
  exit 2
fi
probe="$PWD/.build/debug/jbl-probe"
if [ ! -x "$probe" ]; then
  echo "Build the package first (swift build). No tool was installed or permission changed." >&2
  exit 1
fi
echo "OpenJBL probe: named captured operations only; no pairing or paging."
echo "The paired Tour Pro 3 must already show Connected in macOS."
echo "Approve any macOS Bluetooth permission prompt in the terminal's own context."
echo "Initial check only lists paired devices; it does not open a control channel."
"$probe" list --devices
echo
echo "To run a named suite, use the validate subcommand shown by:"
"$probe" --help
echo
echo "Provide a device identifier interactively; do not paste identifiers into shared logs."
