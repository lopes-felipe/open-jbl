# Captured listening-mode read on the Mac

Date: 2026-11-02. Complete redacted transcript retrieved at 19:54:16 CET through
Copy Diagnostics. Sandboxed universal Release app, ad-hoc signed; exact selected
paired Tour Pro 3, already Classic-connected. User approved Bluetooth access
and confirmed the iPhone JBL app was closed before this test.

The new listening-mode spec sends 0901 with payload 05 00, captured in
session 004 at packets 1270/1274 and repeated twice. The
[fixture](../../../Tests/JBLKitTests/Fixtures/tourpro3/listening-read-session-004.race.txt)
was independently compared byte-for-byte against the private source.

Its reply is a 5B state response with seven payload bytes, unlike the six-byte
5D push layout. Mode is at offset 3. The trailing three bytes remain opaque;
they are not interpreted as acknowledgement status. Unrecognized modes and
layouts do not become confirmed state.

The Mac test opened RFCOMM and completed all four enabled reads:

| Reading | Result |
| --- | --- |
| Case firmware | 5.7.0 |
| Listening mode | ANC |
| Agent battery | 26% |
| Partner battery | 21% |

The session also observed validated incoming firmware events outside pending
transactions. No earbud-version event arrived in this run. Observations are
invalidated when the link closes. They never change policy flags.

The control link closed after completion, with no automatic retry or settings
write. The firmware-query policy conflict is documented in
[the separate review](../firmware-query-review.md). No exception is enabled.
Identity, firmware gating for settings, audible changes and the other M1
acceptance checks remain outstanding. This is not outcome A/B.
