# Session 003: an audible listening-mode change

Date: 2026-11-02. Private source: session-003.pklg, SHA-256 recorded in
research/log.md. User-reported baseline: JBL Headphones 5.38.3, Germany App
Store; earbud firmware 6.0.1; case firmware 5.7.0. Versions and PID have not
been independently decoded. No Mac control was attempted.

## Capture and action

The user reports the logging profile, PacketLogger and official app now work
together. Counts rose from 834 to 1,194 before the action prompt. Fresh traffic
and official-app control coexist; the earlier failure's cause remains unknown.
M1 started at 2026-11-02T18:30:36+01:00, with the fixed deadline
2026-11-16T18:30:36+01:00.

With both buds requested out of the case, the user reported **ANC → Ambient →
ANC**, both changes audible, and visible battery levels L 45%, R 49%, case 16%.
Those levels are reference observations, not decoded telemetry.
Recording was stopped and saved locally with 3,144 records.

The capture includes buffered earlier traffic. Only two mode commands occur
after the observed pre-action packet count of 1,194: packets 1876 and 1970.
Earlier mode commands at packets 87 and 95 are excluded from action attribution.
Host and capture clocks remain offset; packet order and the checkpoint establish
the association, not an assumed wall-clock match.

## Exact observed exchange

The sanitized fixture is
[listening-mode-session-003.race.txt](../../../Tests/JBLKitTests/Fixtures/tourpro3/listening-mode-session-003.race.txt).
It contains six bounded sound-control frames, checked against the private
identifier denylist. Raw captures and detailed analysis remain gitignored with
owner-only permissions.

| Transition | Command payload (0E06 / 5A) | Reply packet | Mode report packet (0901 / 5D) |
| --- | --- | --- | --- |
| ANC → Ambient | 00 0A 0A 04 (packet 1876) | 1881, 87 ms later | 1888, 587 ms after command |
| Ambient → ANC | 00 0A 01 00 (packet 1970) | 1973, 82 ms later | 1987, 683 ms after command |

Replies echo the four command bytes and append two zero bytes. Their status
semantics remain unproven. Report payloads are:

~~~text
Ambient: 05 00 00 0A 07 00
ANC:     05 00 00 01 07 00
~~~

The observed report layout is prefix 05 00 00, mode at offset 3 (01 = ANC,
0A = Ambient for this sequence), then two opaque bytes. The suffix 07 00 is
preserved without assigning a gain or flag meaning.

The outgoing fourth byte also changes (04 versus 00). Its meaning and interaction
with levels/adaptive settings are unknown. Do not turn this into a general
three-byte filter encoder, assume Ambient = 05, or treat the last byte as padding.
Off, TalkThru, other levels and other firmware remain unverified.

The passive TourPro3Sound parser accepts only the observed six-byte type-5D
report layout and the two observed mode values. It rejects acknowledgements,
other prefixes/types/lengths and unknown modes. No send spec is enabled.

## Mid-connection decoding

The trace starts without service/channel negotiation. tshark consequently does
not label these dynamic-channel packets as ATT. Exact raw-L2CAP parsing finds
259 complete ATT-wrapped RACE candidates on one HCI connection:

- 83 outgoing ATT Write Commands (52), handle 0053, CID 0043.
- 176 incoming ATT Notifications (1B), handle 0055, CID 050A.

These envelopes are consistent with the earlier session's Classic GATT path.
Without connection setup, this trace alone does not independently establish
transport, service or peer identity.

The offline Swift decoder recognizes an ATT candidate only when a Write
Command/Notification with a nonzero attribute handle contains exactly one
complete RACE frame. Candidates remain distinct from dissected ATT. It does
not infer identity, capability or permission to send.

Independent exact-envelope parsing agrees with the Swift decoder's metadata for
all 259 candidates. Other observed IDs are 0093, 0E15, 0086, 0055 and 2C83;
their payloads are withheld and semantics remain unresolved.

## Remaining gate

This is the first action-associated listening-mode fixture, not M1 outcome A/B.
Next capture fresh official-app initialization and device information, establish
identity/versions and safe read operations, then prove a guarded public Mac
transport in probe and sandboxed app. Live writes and release gates remain disabled.
