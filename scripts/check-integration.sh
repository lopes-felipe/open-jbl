#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/check-fast.sh
scripts/build-validation.sh "$@"
scripts/check-ui.sh
