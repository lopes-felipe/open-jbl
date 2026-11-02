# Earbud firmware query: approved narrow exception

Status: **approved by the user on 2026-11-02: “Allow only this captured firmware read”.**
The exact named read is enabled and passed a sandboxed Mac test. This overrides
only the specified part of the original plan's §3.4 blocklist.

## Conflict with the plan

The approved plan §3.4 blocks every RACE ID in 1C00–1C1B, including reads;
its only exception is for captured gesture NV transactions. ID 1C07 therefore
could not be enabled by adding capture evidence alone. The user's subsequent
explicit approval authorizes the narrow exception below.
Settings also require known firmware. The only earbud-version exchange located
in the current iPhone capture uses this blocked ID.

## Concrete captured exchange

The official app sends the same request during both initialization sequences
in session 004: packets 795/803/804 and 1153/1162/1163.

~~~text
> 05 5A 03 00 07 1C 00
< 05 5B 03 00 07 1C 00
< 05 5D 0B 00 07 1C 00 00 06 76 36 2E 30 2E 31
~~~

The resulting version is v6.0.1, matching the user's official-app report.
The [sanitized fixture](../../Tests/JBLKitTests/Fixtures/tourpro3/earbud-firmware-session-004.race.txt)
backs byte-exact positive tests and negative tests for all other request shapes.
No upload, image transfer, commit or flash payload is part of this exchange.
The sandboxed Mac query returned 6.0.1. The complete redacted read-test transcript
was retrieved at 20:04:34 CET; case 5.7.0, ANC and agent/partner 23/19% also read
successfully. The channel then closed, with no retry.

## Checks already made

- 0092 replies are eleven bytes; neither known PID nor the Mac-paired address
  has been located. Identity remains unmapped; do not invent field offsets.
- macOS reports firmware metadata 1.0.0, which disagrees with the captured
  earbud firmware. It cannot substitute for the required version check.
- The sandboxed read test now observes all validated incoming firmware events,
  even outside a pending request, with bounded storage and disconnect invalidation.
  Its completed Mac run received no earbud-version event.
- Listening-mode read 0901/module 5 succeeds on the Mac without enabling writes.

## Approved and enforced scope

Exactly one named bootstrap read is permitted: direct RACE command 1C07 with payload
00, on the selected paired Tour Pro 3 over its verified RFCOMM path.
Require this fixture, no arguments, exact model/address binding, bounded
acknowledgement plus validated version notification, and teardown on failure.
No wrapped form, other payload, arbitrary 1C07 operation or other 1Cxx ID would
is permitted. Every other blocklist rule remains unchanged. ID 1C07 stays on
the general blocklist; only the exact direct spec has an exception. Wrapped
forms remain denied, including relay/tunnel forms.

Only a successful version query on the active bound connection, matching 6.0.1,
can enable the bounded captured mode tests. Caller-supplied identity/firmware
flags are cleared by the production session initializer. Case versions and
unsolicited firmware events alone never elevate write permission. Teardown
invalidates binding, observations and verification. This approval authorizes
neither an updater nor a full M1 acceptance claim.
