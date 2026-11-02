# Session 004: initialization and passive telemetry

Date: 2026-11-02. Private source: session-004.pklg; SHA-256 recorded in
research/log.md. The stopped trace contains 2,921 records. The user started a
new trace, force-quit/reopened JBL Headphones and opened device information.
During this session the official app also requested pairing with the case and
permission to send notifications to it; the user approved both. These are
official-app actions. OpenJBL initiated neither pairing nor notification access.

Baseline: app 5.38.3, Germany App Store; earbuds 6.0.1; case 5.7.0.
After the capture, the user confirmed L 45%, R 49%, case 16%, both buds out.
Those levels also match the previous session's reference readings.

## Extraction and corroboration

The trace begins mid-connection. The initial exact-single-frame ATT scan found
359 candidates. Decoding the observed CIDs as ATT allows the existing streaming
codec to recover 387 frames, including concatenated battery queries in a single
ATT value. The earlier single-frame fallback deliberately does not classify
concatenated frames; its smaller count did not prove the queries were absent.

~~~sh
scripts/extract-race.sh --att-cid 0x0043 --att-cid 0x050a \
  research/captures/session-004.pklg research/captures/session-004-context.tsv
.build/debug/jbl-probe decode research/captures/session-004-context.tsv
~~~

CID overrides are offline interpretation of observed channel envelopes, not
service discovery or identity verification. Never hardcode these ephemeral
values in a transport. All recovered RACE frames in this analysis belong to
HCI connection 000B. Other traffic from the case-pairing workflow is not assigned
earbud semantics.

An independent parser isolates direction, HCI connection, CID and attribute
handle, bounds partial buffering, and agrees with the Swift decoder on ordered
type/ID/length/handle/direction/timestamps for all 387 frames.
The reviewed fixture also matches the ordered captured bytes exactly.
Raw logs, forced-context TSV, addresses, names and unrelated payloads stay private.

## Battery

| Source | Captured notification payload | Interpretation |
| --- | --- | --- |
| 0CD6 / 5D, packet 1478 | 00 00 2D | role 0, 45% |
| 0CD6 / 5D, packet 1484 | 00 01 31 | role 1, 49% |
| 000B / 5D, packet 1483 | 00 10 | case, 16% |

The same levels recur in subsequent events. In this session role 0 matches the
reported left reading and role 1 the right reading. This does not establish a
permanent side mapping across agent/partner changes or reconnects. The passive
parser preserves agent/partner roles and does not invent charging or dock state.
Unknown roles, nonzero prefixes, invalid lengths and levels above 100 are rejected.

Packet 1471 contains direct RACE battery queries for roles 01 and 00, alongside
other frames. Replies 1473/1474 contain only a zero byte; they do not identify a
role or carry a percentage. Role-tagged type-5D events arrive afterward.
They are not type 5C, and their role is at payload offset 1 after the zero byte.

The transaction harness now lets a spec declare the event type and role offset.
Tests cover either reply/event order, wrong role/type, notification-only
completion, invalid offsets and bounded duplicate storage. A reply alone still
does not confirm a setting.

## Firmware

- An incoming 1C07 / 5D event at packet 804 contains
  00 00 06 followed by ASCII v6.0.1. The length byte matches the six text bytes.
  The decoded version matches the user's earbud firmware report.
- The captured empty-payload 000F query at packet 1597 gets a one-byte
  acknowledgement (00) at 1598 and a type-5D event at 1599 containing
  00 followed by ASCII 5.7.0. This matches the case firmware report.
- The parser validates the observed headers, declared length where present,
  ASCII numeric version format and component. Acknowledgements are not firmware.
- **1C07 remains blocked for sending.** Passive reception of its version event
  does not authorize an OTA-family query or copying the official initialization.

The sanitized [telemetry fixture](../../../Tests/JBLKitTests/Fixtures/tourpro3/telemetry-session-004.race.txt)
contains only bounded battery/firmware frames. It includes no outbound 1C07,
serial, address, personalization or notification content.

## Wrappers and unresolved identity

Capture evidence distinguishes two wrappers:

- 0093 carries complete Harman AA frames: outgoing AA begins at offset 0,
  incoming response/event AA at offset 1. Observed inner IDs include 06, A4,
  A7 and B1. Unknown/private payloads are withheld. The RACE-only nested-send
  guard does not yet support these mixed-family wrappers, so they stay disabled.
- 0D01 contains a complete nested RACE frame at offset 2 in an outgoing request
  (packet 1413) and an incoming event (1432). The nested ID is 0A0C. This does
  not authorize arbitrary relays or NV writes.

This corroborates the [reference notes](https://github.com/HellzYeahh/earshot/blob/main/docs/research/research_notes/Top%20brand%20headset%20protocols/jbl.md)
on wrapper families. The actual payload shapes come from this user's capture.

0092 is queried twice and returns eleven-byte payloads, but the expected PIDs
20F2/20FD have not been located in either byte order in the recovered payloads.
Its identity layout remains unmapped. The liveness ID 0301 is not observed.
Do not invent either command or call PID/address identity verified.

## Outcome and next gate

Passive parsers and fixtures now cover the observed ANC/Ambient report,
agent/partner/case percentages and earbud/case versions. They are not attached
to a live Mac session. The production catalog remains empty.

Next establish a guarded Mac transport and model/address binding, review safe
read specs and their firmware applicability, and reproduce telemetry before
enabling a reversible Mac write. The installed-app inventory is still a draft.
M1 outcome A/B and all release/hardware gates remain unpassed.
