#!/bin/bash
# Offline checks only. No app launch, Bluetooth acquisition, signing or upload.
set -euo pipefail
cd "$(dirname "$0")/.."
swift_command=(swift test)
if [ "${OPENJBL_HOST_RESTRICTED:-0}" = 1 ]; then swift_command+=(--disable-sandbox); fi
"${swift_command[@]}"
scripts/check-fixtures.sh
python3 -m unittest discover -s Tests/ScriptTests -v
