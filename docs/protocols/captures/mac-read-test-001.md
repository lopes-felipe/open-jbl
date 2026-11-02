# First sandboxed Mac telemetry test

Date: 2026-11-02, Europe/Berlin. The second run's transcript was retrieved at
19:42:11 CET. Hardware: the user's already-paired JBL Tour Pro 3, connected
through macOS before OpenJBL acquired control. Frozen candidate baseline:
earbuds 6.0.1, case 5.7.0, official iPhone app 5.38.3 / Germany.

## Transport and permission

The sandboxed universal Release app was launched through Finder and granted
Bluetooth access by the user. Its paired-device inspection found the selected
Tour Pro 3 connected, with the Airoha SPP UUID's cached SDP record resolving to
RFCOMM channel 21. This channel was discovered, never assumed.
The agent-launched CLI still reports unauthorized; it has not passed the
separate unsandboxed-probe hardware gate.

A startup activation-policy conflict was removed: the app delegate no longer
overrides the main window's regular activation policy after its appearance.
The rebuilt app could then be inspected and operated through F5.
This is an ad-hoc signed research build, not Developer ID release acceptance.

## Captured read catalog

Only three operation names are enabled, all backed byte-for-byte by the
[session 004 fixture](../../../Tests/JBLKitTests/Fixtures/tourpro3/telemetry-session-004.race.txt):

| Spec | Request | Completion |
| --- | --- | --- |
| battery-agent | 05 5A 03 00 D6 0C 00 | 5B / 0CD6 acknowledgement plus 5D / 0CD6 with role 0 at payload offset 1 |
| battery-partner | 05 5A 03 00 D6 0C 01 | Same, with role 1 |
| case-firmware | 05 5A 02 00 0F 00 | 5B / 000F acknowledgement plus 5D / 000F version |

These are explicitly reviewed bootstrap reads for unknown-firmware policy:
no firmware-dependent request fields, settings, initialization sequence, NV or
OTA operations are sent. Cross-firmware compatibility remains untested.
Unexpected or malformed telemetry is rejected by the captured report decoders;
the harness closes on unresolved completion without retrying.
The actual paired address and exact Classic model name are rechecked before
SDP, open and every fragment write.

## Observed results

The Diagnostics read-test action was run twice, sequentially. Each opened
RFCOMM, read case firmware followed by the two battery roles, required zero-status
acknowledgements and decoded notifications, then closed the control link.
No application restart or baseband reconnect occurred between these two runs.

| Run | Case firmware | Agent | Partner | Result |
| --- | --- | --- | --- | --- |
| 1 | 5.7.0 | 32% | 24% | All three reads completed |
| 2 | 5.7.0 | 31% | 24% | All three reads completed after control-channel reopen |

The complete redacted transcripts were obtained through Copy Diagnostics.
The case firmware matches the iPhone baseline. After the second run the user
reported the official app's L 24%, R 30%, case 16%, with both buds out.
The Mac partner reading matches L exactly; agent differs from R by one point.
These are sequential readings, not a simultaneous measurement. Unlike the
session 004 association, agent corresponds to R in this comparison. This
reinforces keeping protocol roles separate from permanent left/right identity.
Charging, dock state and case battery were not queried in this Mac test.

## Limits and next gate

This proves sandboxed public-API RFCOMM access and these telemetry exchanges
on this Mac. It does not establish PID identity, known earbud firmware in the
live session, liveness 0301, a reversible setting change, audio continuity,
disconnected-device no-paging behavior or reconnect/sleep performance.
No setting or action operation is enabled. All blocklists remain enforced.
M1 outcome A/B and every release acceptance flag remain pending.
