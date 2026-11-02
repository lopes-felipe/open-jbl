# Tour Pro 3 operation and evidence matrix

This is the single protocol coverage matrix, not an enabled-operation registry
or a second parity inventory. [FEATURE_PARITY.md](FEATURE_PARITY.md) owns the
required action inventory; [acceptance.json](acceptance.json) owns release
attestations. Observing an ID does not establish arguments, semantics, safety,
availability, authorization or permission to send it.

## Offline audit

The existing private traces were re-audited before requesting additional actions:

| Trace | Reviewed frame count | Interpretation |
| --- | ---: | --- |
| 001 | 148 | Exact ATT frames; initialization only, no reliable action timing |
| 003 | 259 | Exact ATT-wrapped candidates; two audible, checkpoint-associated mode changes |
| 004 | 387 | Stream reassembly, initialization and user-correlated telemetry |
| 005 | 1,005 | Stream reassembly, repeated complete Ambient and ANC readback profiles |

The counts reproduce the existing independent analyses. Session 002 recorded
no HCI/ACL traffic and is not evidence. Session 003's exact-frame scan can miss
concatenated frames; its count is a conservative coverage boundary. CID/handle
overrides used for 004/005 were observed in those captures and are never device
constants. Raw traces, identifiers and unknown payloads remain private.

There are seven production research specs and five sanitized fixtures. Only
five reads and two bounded mode proofs are enabled; none of the remaining
observed IDs below is enabled by this document. The approved direct 1C07/00
query replaces the uncaptured 0301 liveness requirement; it is not an OTA-family
permission. All other blocklist and capture rules remain enforced.

## Enabled research operations

| Spec / request | Exact arguments | Reply / authoritative state | Mac hardware evidence | Missing evidence |
| --- | --- | --- | --- | --- |
| earbud-firmware / 1C07 | 00 | 5B zero ACK plus validated 5D component/version | 6.0.1 read in sandboxed app | Probe run, repeated reconnect contract |
| battery-agent / 0CD6 | 00 | 5B zero ACK plus role-0 5D percentage | Multiple sandboxed reads | Stable physical-side mapping, charging/dock states |
| battery-partner / 0CD6 | 01 | 5B zero ACK plus role-1 5D percentage | Multiple sandboxed reads | Stable physical-side mapping, charging/dock states |
| case-firmware / 000F | Empty | 5B zero ACK plus validated 5D version | 5.7.0 read in sandboxed app | Probe run |
| listening-mode / 0901 | 05 00 | 5B seven-byte complete mode profile | ANC and Ambient separately read | Other modes/levels and unknown profiles |
| test-ambient / 0E06 | 00 0A 0A 04 | Exact echo/zero reply, target 0901 notification, fresh complete target profile | Confirmed by sandboxed readback and audible user check | Probe and reconnect proof; general driver |
| test-anc / 0E06 | 00 0A 01 00 | Same contract with ANC target profile | Audible and separately read; change transaction failed | Exact Mac reply/notification mismatch; probe proof |

Reads and mode proofs have software deadline/cancellation coverage, but safe
hardware interruption behavior is not established by those tests. A transmitted
write is never automatically retried. The ANC failure must be captured with
stage-specific diagnostics; a later read or audible change does not repair the
failed transaction's outcome.

## Remaining original protocol workstreams

“Observed” means an ID appears in 004/005 unless another trace is named.
External-note IDs remain hypotheses. For every incomplete row, obtain exact
requests/arguments, replies, authoritative state, persistence and cross-feature
limits before enabling a spec. Cancellation is unproven for every unfinished
write/action; Find My Buds additionally needs a captured safe Stop contract.

| Feature | Candidate IDs | Existing capture coverage | Missing operation/state/cancellation evidence |
| --- | --- | --- | --- |
| Identity and versions | 0092; 1C07 / 000F | 0092 request/reply observed; versions decoded | Decode PID/address layout; name fallback is not a decoded PID |
| Battery L/R, case and charging | 0CD6; 000B / 0009 | Role reads enabled; case 000B percentage decoded passively; 0009 observed | Physical side changes, dock/charging/disconnect transitions and safe case query |
| Listening modes and levels | 0901 module 5/7; 0E06 | ANC/Ambient exact shapes only | Off, TalkThru, min/mid/max levels, unrelated fields, docked refusal, push behavior |
| Adaptive ANC | 0E26 | ID observed | Read/write distinction, ranges and calibration lifecycle; proof-gated |
| EQ preset and on/off | 0901 module 0; 0900 | 0901 present, module-0 action association unreviewed; 0900 not seen | Every preset, toggle, baseline/readback and persistence |
| Custom ten-band EQ | 0E03; 09FD | Not observed in reviewed streams | Five reference curves, sample rate/packing, apply order; two-session proof |
| Voice prompts | 0901 module 1; 0900 | Generic 0901 present; matching action absent | Toggle shapes, unrelated module fields and readback |
| Audio quality | 0901 module 6; 0900 | Generic 0901 present; matching action absent | All choices and cross-feature effects |
| Auto power-off | 2C83 / 2C82 module 1 | 2C83 observed | Enable/time compound layout, every interval, preserve unrelated bytes |
| Find My Buds | 2C00 / 2C01 | Not observed | Side selection, start/Stop ACK/state, volume warnings, safe abort/disconnect behavior |
| Spatial / head tracking | 0046 / 0047; 0048 / 0049 | Not observed | Toggles, unavailable states and mutual constraints |
| Hi-Res | 0075 / 0076 | 0075 observed | Toggle, current audio constraints, readback/disconnect effects |
| Low-volume EQ | 0058 / 0059 | 0058 observed | Toggle/write/readback and other sound-mode effects |
| Smart Talk | 0060 / 0061 | 0060 observed | All options, activation/delay, readback |
| Silent Now | 0068 / 0069 | 0068 observed | Duration, start/stop, timer/disconnect behavior |
| Auto play/pause | 000C / 000A | 000C inbound in 001 | Toggle/readback and in-ear transitions |
| Personi-Fi toggle | 0062 / 0063 | 0062 observed | Toggle while preserving existing profile; never export profile payload |
| Sources list | 0066; 0055 | Both IDs observed | Read-only list layout and redaction; no multipoint mutations |
| Case brightness/timeout/tap/24h | 0079 / 0081; 0080 / 0082 | All IDs observed without per-setting attribution | Every setting/action, ranges, preserved bytes, persistence, case reachability |
| Case time sync | 0090 | Not observed | Timestamp epoch/unit/timezone, exact payload, authoritative readback |
| Case language/shortcuts | Unmapped | No attributed action | Inventory if present; proof-gated |
| Gestures | 0A00 / 0A0C; 0A01 / 0A0D, 0A09 reload, 0D01 relay | Reads observed; nested 0A0C read observed | Every action per bud, exact NV key/value set, ACK then single reload within 2 s, safe abort |
| VoiceAware / rename | Unmapped | No attributed action | Inventory if present, exact fields and cancellation; proof-gated |

0093 carries observed AA frames, not a proven nested RACE payload; no mixed
wrapper sends are enabled. 0D01's observed nested read does not authorize NV
writes. Initialization contains blocklisted IDs, including 0CD5/1101; do not
replay the initialization sequence wholesale.

## Promotion checklist

Promote each operation only after all applicable boxes have recorded evidence:

- Exact action marker, component, firmware and captured request arguments.
- Sanitized fixture with request, response and authoritative state/readback.
- Completion/correlation, refusal statuses, deadlines and cancellation points.
- Applicability, field preservation, sensitive fields and dispatch preconditions.
- Negative/replay tests; unknown shapes refuse before hardware transmission.
- Sandbox and probe validation where required; audible/physical observations
  remain attributed to the user, not inferred from transport completion.

Firmware installation, reset, wallpaper, host notification forwarding, hearing/
fit profile generation, Auracast and multipoint changes remain the original
excluded/proof-gated work. No missing required action is reclassified here.
