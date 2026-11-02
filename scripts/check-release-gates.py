#!/usr/bin/env python3
"""Manual evidence attestations, checked before any signing/upload credentials."""
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
try:
    report = json.loads((root / "docs/acceptance.json").read_text())
except (OSError, ValueError):
    sys.exit("Release blocked: acceptance report is missing or invalid JSON.")
if not isinstance(report, dict):
    sys.exit("Release blocked: acceptance report must be an object.")
errors = []


def evidence_file(base, relative):
    """Reject absolute paths, parent traversal and symlinks outside evidence."""
    if not isinstance(relative, str) or not relative:
        return False
    path = pathlib.Path(relative)
    if path.is_absolute() or ".." in path.parts:
        return False
    resolved = (base / path).resolve()
    return resolved.is_relative_to(base.resolve()) and resolved.is_file()


if report.get("schemaVersion") != 1:
    errors.append("acceptance schema is unknown")
if report.get("m1Outcome") not in ("A", "B"):
    errors.append("M1 outcome A/B has not passed")
evidence = report.get("m1EvidenceReport")
if not isinstance(evidence, str) or not evidence.startswith("docs/"):
    errors.append("M1 evidence report is missing")
elif not evidence_file(root / "docs", evidence.removeprefix("docs/")):
    errors.append("M1 evidence report is missing or outside docs")
if report.get("inventoryFrozen") is not True:
    errors.append("official-app inventory is not frozen")
actions = report.get("requiredActions")
if not isinstance(actions, list) or not actions:
    errors.append("required-action inventory is empty")
else:
    for action in actions:
        if not isinstance(action, dict) or action.get("hardwareVerified") is not True or not action.get("fixture"):
            errors.append("a required action has no hardware/fixture evidence")
        elif not evidence_file(root / "Tests/JBLKitTests/Fixtures", action["fixture"]):
            errors.append("a required action fixture is missing or outside the fixture directory")
required_checks = {
    "noPairingOrPaging", "unknownFirmwareReadOnly", "boundedRecovery",
    "diagnosticsRedacted", "sandboxBluetoothVerified", "macOS14CleanInstall",
    "currentMacOSHardware", "reconnectAndWake", "batteryDrain",
    "developerIDHardware", "publishedGaps"
}
checks = report.get("checks", {})
if not isinstance(checks, dict):
    checks = {}
    errors.append("acceptance checks must be an object")
for check in sorted(required_checks):
    if checks.get(check) is not True:
        errors.append(f"acceptance not recorded: {check}")
if errors:
    print("Release blocked:\n- " + "\n- ".join(errors), file=sys.stderr)
    sys.exit(1)
print("Recorded release gates passed. Notarization and artifact validation still required.")
