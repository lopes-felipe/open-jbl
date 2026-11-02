# M1 feasibility run

Status: **active — capture and inventory**.

| Field | Value |
| --- | --- |
| Tour Pro 3 available for tests | User confirms audio playback and official-app connection after recovery |
| iPhone logging profile | Reinstalled; user reports JBL works with profile and PacketLogger running |
| iPhone USB connection | Observed on USB; user confirms connected and trusted |
| PacketLogger | Sessions 001/003/004/005 saved and analyzed privately |
| Capture supplied and decoded | Seven enabled research specs, five fixtures; sandboxed telemetry and Ambient proof; ANC transaction remains unresolved |
| Official app version / region | User reports 5.38.3 / Germany after connection recovery |
| Earbud firmware / case firmware | 6.0.1 / 5.7.0, user-reported and matched by captured version strings |
| Developer ID distribution credentials | User has a paid account; local certificate/private-key availability must be verified |
| Tools | Xcode, Swift, tshark 4.6.8 and PacketLogger 26.0.0 (Additional Tools for Xcode 27.2) present |
| Start (ISO-8601 and timezone) | 2026-11-02T18:30:36+01:00 (Europe/Berlin, CET) |
| Deadline (start + 14 calendar days) | 2026-11-16T18:30:36+01:00 (fixed) |
| Outcome A, B or C | Not determined |

Start when buds, iPhone/PacketLogger and capture tooling are all ready. Freeze the
deadline at kickoff. Days 1–3: inventory/capture; 4–8: decode; 9–12: reproduce on
Mac; 13–14: sanitized fixtures and evidence report.

A requires identity, telemetry, a reversible change and resulting state through
public Mac APIs in probe and sandboxed app. B additionally requires reproducible
initialization across reconnect/restart without distributing extracted secrets.
C stops the control app and publishes only independently proven telemetry.

Record transport, fixture IDs, app/firmware versions, controller competition,
no-paging observations and build signing identity. Synthetic tests do not count.

## Approved liveness amendment and grouped work

The user approved replacing the uncaptured 0301 liveness requirement with the
exact captured, separately approved **direct 1C07 / payload 00** earbud-firmware
query. This is the same narrowly reviewed exception documented in
[firmware-query-review.md](protocols/firmware-query-review.md). It does not
authorize any other 1Cxx request, alternate payload or wrapper. 0301 remains
disabled unless captured. All other M1 A/B requirements and the fixed deadline
above remain unchanged; no outcome is declared by this amendment.

The latest direction is to complete offline implementation first, then use
grouped hardware sessions without scheduling appointments now. Follow
[GROUPED_VALIDATION.md](GROUPED_VALIDATION.md), with missing protocol evidence
tracked in [OPERATION_EVIDENCE.md](OPERATION_EVIDENCE.md). A hardware-dependent
feature remains disabled until its required evidence is reviewed.

The remainder of this document is the historical run log, not the current
operation registry. Later capture reports supersede earlier “not yet tested”
observations; the inventory and acceptance attestations remain canonical.

The official iPhone app stopped connecting during the first capture attempt
while audio still worked. Reopening the app, checking permission, cycling the
buds and restarting did not restore control. The user reports the app connected
after removing the logging profile and restarting again. At that point the
profile stayed removed while the saved trace was analyzed. This observation
does not isolate the failure's cause. No OpenJBL control commands were sent.

The saved trace yields 148 RACE-shaped ATT frame candidates, not verified
operations. Capture timestamps differ from the host clock and include buffered
history, so action timing must be established before promoting any operation
to captured evidence.

The [session 001 analysis](protocols/captures/session-001.md) records two
byte-identical candidate initialization sequences and GATT over Classic Bluetooth
on the iPhone. No Mac transport, safe reversible operation or M1 outcome is proven.

A second test with the logging profile removed opened a Live iPhone trace, but
recorded zero HCI/ACL packets even when the user changed listening modes and
heard the changes. The empty trace was stopped. Opening a Live window alone is
not evidence of recording.

The user subsequently reinstalled the profile and reports that JBL Headphones
and PacketLogger now work together. Fresh packet counts rose from 834 to 1,194,
including HCI and ACL traffic. The earlier connection failure is therefore not
consistently reproducible; its cause remains unknown. Capture prerequisites
are now established, so the fixed M1 clock starts at the timestamp above.
The [session 003 report](protocols/captures/session-003.md) records the audible
ANC → Ambient → ANC exchange, sanitized fixture and passive parser. Fresh app
initialization, identity/version decoding and Mac transport proof remain ahead.

The [session 004 report](protocols/captures/session-004.md) now documents fresh
app initialization, battery levels matching the user and captured firmware
strings. It also records the official app's case-pairing/notification consent.
The [Mac read report](protocols/captures/mac-read-test-001.md) records two
successful sandboxed RFCOMM runs using three captured telemetry specs.
Identity/PID layout, live earbud-firmware verification, the unsandboxed probe
and a reversible change remain ahead; outcome A/B is not declared.
