# Session 001: offline structural analysis

Analysis date: 2026-11-02. Source: the user's private iPhone PacketLogger trace,
saved locally as session-001.pklg. Raw trace, TSV, analysis script and detailed
metadata report remain under gitignored research/ with owner-only permissions.
No addresses, names, serials, payloads or personalization data are published here.

This is capture evidence for framing and observed traffic, not a set of reviewed
operation specs. No operation is enabled, no Mac transport is verified, and M1
has no A/B outcome.

## Baseline and provenance

The user reported these versions after restoring the official app's connection:

| Item | User-reported value |
| --- | --- |
| JBL Headphones | 5.38.3 |
| Earbud firmware | 6.0.1 |
| Case firmware | 5.7.0 |
| App Store region | Germany |

These are the current reported baseline. The trace itself has not independently
established versions or PID. The installed-app feature inventory is not frozen.
Capture timestamps include buffered history and do not align with the host
clock; there is no reliable timestamped action log for individual setting edits.

The official app stopped connecting while audio still worked. Basic recovery
checks failed. The user reports that profile removal and an iPhone restart
restored app control. This does not isolate the cause. The profile remains
removed, and this analysis did not acquire a new connection.

## Transport observations

- HCI Connection Complete events (0x03), status 0, link type 0x01 (ACL), at
  packet numbers 19860 and 27754 establish two Classic connection instances.
  The peer addresses match; their actual values are withheld.
- Their connection handles are 0x000C and 0x000D. These are ephemeral trace
  identifiers, not device identity.
- ATT uses dynamically allocated L2CAP channels associated with PSM 0x001F.
  This supports **GATT over BR/EDR** for these exchanges, rather than BLE.
  ATT over BR/EDR is defined in the Bluetooth SIG's
  [Attribute Protocol specification](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Core-54/out/en/host/attribute-protocol--att-.html).
- The expected service UUID 5052494D-2DAB-0341-6972-6F6861424C45 appears in
  service discovery, including packet 20278. Characteristic discovery at
  packet 20621 lists value handles 0x0053 and 0x0055 under that service.
- Outgoing RACE commands use ATT Write Command (0x52), handle 0x0053.
  Incoming frames use ATT Handle Value Notification (0x1B), handle 0x0055.
  All 118 incoming RACE frames have the expected service in tshark's context.
  Attribute handles must be discovered on each device; these are not constants
  for an implementation.
- A disconnect at packet 27593 reports reason 0x13, Remote User Terminated
  Connection. This is an observed reason code, not an explanation for the
  later app connection failure.

Apple documents LE and BR/EDR support in
[Core Bluetooth](https://developer.apple.com/documentation/corebluetooth).
This is a reason to investigate a public Mac GATT path if the planned RFCOMM
proof fails; it does not prove macOS discovery, identity matching, sandbox access
or control acquisition. RFCOMM remains untested. No LE pairing action is justified
by these observations.

## Framing and request/reply observations

All 148 ATT RACE candidates are complete, exact frames within individual ATT
values: sync 05, type, LE16 length including the two-byte ID, LE16 ID, payload.
There are 30 type-5A, 30 type-5B, 53 type-5C and 35 type-5D frames.
This capture does not exercise RACE fragmentation or concatenation.

Independent exact-packet parsing agrees, in order, with the Swift streaming
decoder on timestamp, direction, handle, type, ID and payload length for every
ATT frame. Raw L2CAP scanning also produces false positives from unrelated
traffic; those are excluded from this report.

Two groups each contain 15 outgoing commands with byte-identical payloads in
the same order:

~~~text
0A00 0A0C 0A00 0006 0E30 0CD4 0CD4 0D00
0A00 000E 0CD5 1C07 0CD4 0A00 0A00
~~~

The first group's commands occupy packets 20638–20723; the second group's
commands occupy packets 29187–29286. Each outgoing command has a later incoming
type-5B frame with the same ID on the same connection. Observed delays range
from 36 to 195 ms. There are no overlapping outstanding commands with the same
ID in either group, and no unmatched type-5B frames.

This is a structural pairing candidate. Payload status semantics, authoritative
state, idempotency, side effects and firmware independence are not established.
Receiving type 5B is not a confirmed setting change.

| ID | Outgoing 5A | Incoming 5B | Incoming 5C | Incoming 5D |
| --- | ---: | ---: | ---: | ---: |
| 0006 | 2 | 2 | 0 | 0 |
| 000B | 0 | 0 | 0 | 3 |
| 000C | 0 | 0 | 4 | 0 |
| 000E | 2 | 2 | 0 | 2 |
| 0082 | 0 | 0 | 0 | 2 |
| 0093 | 0 | 0 | 0 | 24 |
| 0901 | 0 | 0 | 49 | 2 |
| 0A00 | 10 | 10 | 0 | 0 |
| 0A0C | 2 | 2 | 0 | 0 |
| 0CD4 | 6 | 6 | 0 | 0 |
| 0CD5 | 2 | 2 | 0 | 0 |
| 0D00 | 2 | 2 | 0 | 0 |
| 0E30 | 2 | 2 | 0 | 0 |
| 1C07 | 2 | 2 | 0 | 2 |

The captured official app sends 0CD5 and 1C07, both blocked by OpenJBL's safety
policy. Their presence does not override the blocklist or authorize replay.
The repeated sequence must not be copied wholesale into a handshake.

## Incoming updates and unresolved layouts

- ID 0901 occurs as 49 type-5C frames with four-byte payloads and two type-5D
  frames with six-byte payloads. These short events do not independently verify
  the proposed module-5 read layout or ANC/EQ meanings. There is no outgoing
  0901 request here.
- ID 0093 occurs in 24 type-5D frames, each with an eight-byte payload. Searching
  all payload offsets finds no complete embedded RACE frame. Its proposed
  tunnel wrapper remains unverified; these events must not be force-unwrapped.
- IDs 000B, 000C and 0082 have incoming-only traffic. Their names in external
  notes do not establish battery, auto-play/pause or case-setting semantics.
- The planned liveness query 0301, identity query 0092, battery query 0CD6 and
  listening-mode write 0E06 do not appear among these ATT frames.
- No captured mode/EQ write and authoritative read-back are tied to a known
  user action. Incoming traffic alone cannot establish parity.

## What is needed next

1. Inventory the working official app against the reported baseline.
2. Establish trustworthy action timing and a capture method that permits the
   official app to remain connected, before requesting more live recording.
3. Identify PID, versions and safe initialization without replaying blocked
   commands. Decode candidate fields against known user-visible values.
4. Capture one reversible setting and resulting authoritative state, then
   review sanitized fixtures, typed arguments, completion and firmware policy.
5. Prove a public, guarded Mac transport in both probe and sandboxed app.

Until those steps pass, the production operation catalog stays empty and all
release evidence gates remain unchanged.
