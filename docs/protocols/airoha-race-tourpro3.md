# Tour Pro 3 evidence report

**Captured iPhone exchanges, sandboxed Mac telemetry and bounded Ambient proof.
ANC's change contract and the full M1 gate remain unverified.**

The [session 003 report](captures/session-003.md) adds a user-observed audible
ANC → Ambient → ANC exchange, one sanitized fixture and a passive listening
report decoder. Its actual Ambient value differs from the initial hypothesis.
Only the exact two captured research mode operations are enabled.

The [session 004 report](captures/session-004.md) adds captured battery queries,
role-tagged percentage events, earbud/case version strings and a second fixture.
It also proves that 0093 carries AA frames, while 0D01 carries nested RACE.
Mixed-family sends remain disabled until their guard rules are implemented.

The [session 005 report](captures/session-005.md) establishes distinct exact
Ambient and ANC readback profiles. The [latest Mac test](captures/mac-mode-test-002.md)
confirmed Ambient from notification/readback and user listening. ANC was audible
and separately read back, but its change reply/notification contract failed.

A private iPhone PacketLogger trace was saved on 2026-11-02. Offline decode
found 148 RACE-shaped ATT frame candidates: 30 outgoing on handle 0x0053 and
118 incoming on handle 0x0055. This supports investigating the RACE envelope;
it does not verify device identity, operation semantics or a Mac control link.
Raw L2CAP scanning also produced false positives and is not corroborating evidence.
The raw capture and extracted TSV remain gitignored with owner-only permissions.

The official app lost control while audio remained connected. After unsuccessful
basic recovery checks, the user removed the logging profile and restarted the
iPhone; the official app then connected. The cause is not isolated. Further work
initially used the saved trace with the profile removed. A later reinstall
allowed live capture and official-app control together. Current versions are
user-reported and match the session 004 strings. PID/address identity and
the remaining Mac acceptance tests remain outstanding.

Detailed packet references, counts, request/reply observations and unresolved
layouts are in the [session 001 report](captures/session-001.md). HCI and L2CAP
metadata support GATT over Classic Bluetooth for these iPhone exchanges.

The supplied plan identifies TourPro3LeControl, PID 20F2/case 20FD and possible
RFCOMM service 00000000-0000-0000-0099-AABBCCDDEEFF.
The [first Mac read report](captures/mac-read-test-001.md) now records cached SDP
resolution to channel 21 and two successful sandboxed RFCOMM telemetry tests.
GATT service 5052494D-2DAB-0341-6972-6F6861424C45 was observed on the iPhone;
Mac acquisition remains unimplemented/unverified.
Do not guess channel, authentication or payload.

| Envelope field | Bytes |
| --- | --- |
| Sync | 05 |
| Type | 5A / 5B / 5C / 5D |
| Length | LE16, includes two-byte ID |
| ID | LE16 |
| Payload | length − 2 |

The independent offline codec caps total frames at 65,539 bytes, buffered data
at two frames, and partial framing at five seconds. Embedded 05 is payload.
Unknown frames do not establish support or update unrelated state.

0301 remains uncaptured and disabled. 0092 identity is unmapped. Only the
captured 0CD6 battery, 000F case firmware, 0901/module-5 mode and explicitly
approved direct 1C07 earbud firmware read shapes are enabled, alongside the
bounded mode proof operations. No broader command applicability is inferred.
Relay 0D01/tunnel 0093 need captured wrappers and inner catalog matches.

Record identity/PID, firmware, statuses, roles, unsolicited updates, initialization,
argument ranges, preserved fields, read-back and safe aborts. Link every operation
to sanitized fixture/provenance, official-app action, firmware and hardware result.
Unmapped nonzero status stays unmapped until reproduced. No M1 outcome yet.
