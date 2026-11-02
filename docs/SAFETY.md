# Safety boundary

Five captured bootstrap reads and two bounded research mode operations are
enabled. Normal feature drivers and other setting/action operations are not
enabled. Every send requires a
reviewed official-app capture. External docs and synthetic tests are not evidence.
Only internal JBLKit source tables construct specs. Clients select names and
typed args; they cannot inject encoders or evidence.

GuardedSession checks membership, arguments, evidence, identity, experimental
policy, confirmation, firmware, exact framing, nested specs and blocklists before
fragmentation. The first rejection emits zero bytes. No raw-send UI or CLI.

Source-defined operation metadata additionally constrains model/case PIDs,
target component, firmware applicability, capabilities and preconditions at
dispatch, including nested operations. Declared payload ranges must fit; a
preserved field must equal a device value observed within the five-second
readback window. Missing/stale/mismatched preservation evidence is rejected.
These checks do not create a compound-write implementation or enable an
uncaptured setting. Actual writes still require the owning session's fresh
read and authoritative reconciliation.

Response/total deadlines and delayed effects are bounded; the transport retains
its fixed five-second fragment deadline. The exact captured mode proofs declare
a 40-second total and firmware 6.0.1 explicitly. Role-byte correlation must
match the declared completion contract. Catalog integrity runs in self-test.

The five bootstrap reads are reviewed as firmware-independent request shapes
for policy purposes: role/module selectors or empty payloads, with captured telemetry
decoders. They have only been tested on the recorded baseline; this designation
does not claim compatibility with other firmware. Exact model-name/address
binding is checked before acquisition and every write. Unknown firmware still
cannot enable a setting change.

The user explicitly approved only the direct captured 1C07/payload-00 version
query as an exception to plan §3.4. It remains generally blocklisted: different
payloads, non-read specs, other models, missing evidence, altered completion
contracts and all wrapped forms remain denied. See firmware-query-review.md.

Production sessions discard caller-supplied identity/firmware booleans. Write
permission requires the active transport's exact selected paired address/name
binding and a successful live version query matching 6.0.1. Name is the plan's
temporary PID fallback, not a claim that 0092 is decoded. Teardown revokes this
permission. Unsolicited version events alone and case versions cannot grant it.

The complete captured Ambient/ANC requests are research-only. One lease covers
fresh baseline read, at most one write, matching reply/state and fresh read-back.
Unmatched opaque fields prevent a write or report unconfirmed after one.
No automatic rollback, mode restoration or retry follows a failure. Session
005 establishes exact profiles 07 00 05 for ANC and 07 00 06 for Ambient; the
last byte remains uninterpreted. These complete profiles are checked by mode.
The next Mac Ambient test passed; ANC's change reply/notification check failed,
despite audible ANC and a separate read. It remains unverified.

All dangerous NV operations including 0A09 reload are denied. An exception needs
the exact captured ID/key/value transaction and failed-write/no-reload tests.
The metadata schema can describe exact captured full payloads, their key/value
ranges and a reload window no longer than two seconds; declaration never
overrides the current blocklist. No NV spec is enabled, and no atomic NV engine
or standalone reload is exposed. No OTA service or speculative NV writes exist.

Acquisition requires selection/pairing, existing Classic ACL, control need,
permission, awake and not released. Recheck on the Bluetooth thread before
SDP/open/write. No inquiry, pairing, openConnection or guessed channel. An ACL
disconnect can race an OS call; close late channels immediately and measure
this on hardware, without claiming atomicity.

IOBluetooth objects stay on one run loop; CoreBluetooth objects on one serial
queue. CoreBluetooth currently only reports permission/power. Callback bytes are
copied synchronously to bounded ordered ingress; overflow closes. PendingSlot
resumes once. Fragments are serialized and buffers retained until completion or
teardown. A failed/cancelled send poisons the link.

The M1 harness reserves before awaiting, bounds replies/fragments, never retries
writes and closes after unresolved completion. Reads return protocol responses.
Mode tests return confirmedMode only after authoritative state and complete
read-back match, with changed=false when no mode write was needed. The observed
hardware mismatch did not return confirmedMode. Offline session/UI work proceeds
before the grouped hardware session; feature promotion and release remain
behind the original evidence gates.

The source-defined telemetry/Ambient/ANC suites share this send path. User
prerequisite confirmation is required for the mode suites. Each suite acquires
once, records structured stage failures, stops affected write sequences and
releases control. A human observation never changes the protocol outcome.
Reports are retained separately so a later run does not erase a failure.

Payloads are withheld from diagnostics/export, including unknown, nested and
personalization traffic. Text also masks known names, serials, addresses and
reverse hex; address-shaped strings are masked even if unknown. No persistent
frame logs or upload. Raw research traces never become diagnostic transcripts.
