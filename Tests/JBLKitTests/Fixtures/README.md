The first sanitized Tour Pro 3 fixture records the user's audible
ANC → Ambient → ANC sequence in session 003. See its metadata and
docs/protocols/captures/session-003.md for provenance and remaining limits.
This enables passive decoder tests, not a production operation.

Session 004 adds captured battery queries/events and version reports, matched
against user-visible values. Its incoming 1C07 firmware event does not authorize
sending an OTA-family command. See the initialization report for pairing context
and remaining identity limits. Its exact battery-agent, battery-partner and
case-firmware requests back their bootstrap specs. Separate fixtures back the
listening-mode read, the user-approved exact firmware query and the two guarded
mode proof requests. No action or initialization sequence is replayed. See the
Mac mode report for the unconfirmed field comparison; fixtures do not establish
general mode/level support.

Tests construct synthetic frames in code. Synthetic frames establish parser and
policy behavior only; they are never evidence for device control.

Reviewed fixtures belong under tourpro3/, harman-aa/ or harman-p4/. See
docs/CAPTURING.md for the provenance and sanitization requirements.
