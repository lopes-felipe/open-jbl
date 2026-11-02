#!/bin/bash
# Runs actual XCUITests against launch-only synthetic state. No Bluetooth calls.
# A graphical macOS login is required; host launch restrictions are failures.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 0 ]; then echo "Usage: $0" >&2; exit 2; fi
umask 077
mkdir -p build/UITests/Results
run="$(mktemp -d "$PWD/build/UITests/Results/run.XXXXXX")"
bundle="$run/OpenJBL.xcresult"
summary="$run/summary.json"
echo "Offline UI test results: $bundle"
ui_command=(xcodebuild -quiet -project OpenJBL.xcodeproj -scheme OpenJBL
  -configuration Debug -destination 'platform=macOS'
  -derivedDataPath "$PWD/build/UITests/DerivedData"
  -resultBundlePath "$bundle" -only-testing:OpenJBLUITests
  -parallel-testing-enabled NO
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60
  -maximum-test-execution-time-allowance 120
  CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=YES)
if [ "${OPENJBL_HOST_RESTRICTED:-0}" = 1 ]; then
  ui_command+=(-IDEPackageSupportDisableManifestSandbox=YES 'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox')
fi
ui_command+=(test)
status=0
"${ui_command[@]}" || status=$?
if [ ! -d "$bundle" ]; then
  echo "UI tests did not produce an xcresult bundle; no runtime validation passed." >&2
  if [ "$status" -ne 0 ]; then exit "$status"; fi
  exit 1
fi
if ! xcrun xcresulttool get test-results summary --path "$bundle" --compact > "$summary"; then
  echo "Could not read the UI test result summary." >&2
  if [ "$status" -ne 0 ]; then exit "$status"; fi
  exit 1
fi
# A successful build with zero selected tests is not a UI test pass.
summary_status=0
python3 - "$summary" <<'PY' || summary_status=$?
import json, sys
try:
    with open(sys.argv[1]) as file:
        summary = json.load(file)
except (OSError, ValueError):
    sys.exit("UI test summary is missing or invalid.")
if not isinstance(summary, dict):
    sys.exit("UI test summary has an unknown shape.")
counts = [summary.get(key) for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests")]
if any(type(value) is not int for value in counts):
    sys.exit("UI test summary has invalid test counts.")
total, passed, failed, skipped = counts
if summary.get("result") != "Passed" or total < 5 or passed != total or failed != 0 or skipped != 0:
    sys.exit(f"UI runtime validation failed: total={total}, passed={passed}, failed={failed}, skipped={skipped}.")
print(f"UI result summary: {passed} tests passed.")
PY
if [ "$status" -ne 0 ]; then
  echo "xcodebuild test failed; the UI runtime check is not passed." >&2
  exit "$status"
fi
if [ "$summary_status" -ne 0 ]; then exit "$summary_status"; fi
echo "Offline UI runtime checks passed."
