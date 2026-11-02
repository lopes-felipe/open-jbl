# Implementation and gates

Updated 2026-11-02. Offline integration in progress, not v1. The integrated
package passed 120 tests, the universal Release app built successfully, and
the UI test bundle compiled. An explicit-keychain Developer ID signature and
entitlement checks passed. Actual UI execution/self-test are blocked by this
agent host; historical checks below retain their original attribution.

## Delivered

- Swift 6/macOS 14 package, checked-in Xcode host and shared scheme.
- Sandboxed menu bar/window, explicit paired-device inspection and permission
  flow, Settings, About disclaimer, opt-in SMAppService login item.
- Dedicated Bluetooth run loop, guarded SDP/RFCOMM, cached-service resolution,
  async writes, MTU/flow control and bounded completion deadlines.
- Bounded ordered ingress with reserved terminal slot, generations and
  cancellation-safe, exactly-once pending continuations.
- RACE incremental codec with partial-frame expiry.
- Typed internal operation registry, capture/identity/firmware/confirmation
  policy, nested-message validation, blocklists and poisoned-stream teardown.
- Dispatch-enforced operation applicability, correlation/preconditions,
  bounded deadlines, preserved/sensitive field ranges and catalog integrity.
  Exact NV proof metadata cannot override the blocklist; no NV operation is
  enabled. Metadata and complete production-fixture contract tests run
  independently of hardware.
- M1 transaction harness matching responses and role-correlated indications
  in either order. Protocol responses never mean confirmed settings.
- Payload-withholding redactor, copy/export and offline TSV decoder.
- Mid-connection ATT candidate recognition and a captured passive ANC/Ambient
  report parser, backed by the sanitized session 003 fixture.
- Session 004 passive battery/firmware parsers and fixture; explicit event type
  and role offset in completion matching; optional observed ATT CID overrides.
- Probe with no raw send path, unit tests, CI and gated release scripts.
- Five fixture-backed bootstrap reads and a bounded sandboxed Diagnostics test.
  Two Mac RFCOMM runs completed case firmware and both battery roles, with the
  control channel closed/reopened between runs. See the Mac read report.
- A fourth captured bootstrap read for listening mode; sandboxed Mac read
  returned ANC. Bounded passive firmware observations do not elevate policy.
  The user subsequently approved the exact captured direct 1C07/payload-00
  version read; it returned 6.0.1 on the Mac. Other 1Cxx and wrapped forms remain
  blocked. Production verification derives from the live binding/query.
- Exact captured Ambient/ANC research operations with one compound lease.
  Session 005 supplies distinct complete mode readback profiles. Sandboxed
  Ambient passed notification/readback and audible checks. ANC was audible and
  separately read back, but its change reply/notification check still failed.
- An offline operation/evidence matrix and numbered grouped capture, feature
  validation and release checklists; see OPERATION_EVIDENCE.md and
  GROUPED_VALIDATION.md. The required inventory and acceptance attestations
  retain their original ownership and gates.
- Reusable fast and universal integration checks, Developer ID selection with
  no local ad-hoc fallback, relocated self-test/hash/entitlement checks,
  a user-terminal probe launcher and manually dispatchable CI. Script
  regressions exercise missing/ambiguous signing identity and failing
  signature/self-test paths without accessing a real keychain.
- DeviceSession owns complete snapshots and the single store attachment;
  bounded scheduling, coalescing, cancellation retirement, intents, recovery,
  workflow leases and guarded discovery have offline regression coverage.
  Passive Classic connection/power events, sleep/wake, idle release and Release
  Controls are integrated into the app. No unverified workflow is enabled.
  Visible-only battery refresh uses a 120-second per-role freshness budget and
  stops while hidden or running an exclusive workflow.
- Snapshot-driven window/menu views, availability reasons, local EQ presets,
  notification hysteresis, opt-in login item, original icon and five synthetic
  XCUITests are implemented. Local execution failed before runner launch because
  the agent lacks LaunchServices access; actual runtime checks are also in CI.
- Named app/probe validation suites share the guarded session; stage-specific,
  payload-free diagnostic reports preserve failed runs. Their presence does not
  establish feature availability or hardware acceptance.

## Remaining

| Milestone | Status | Missing exit evidence |
| --- | --- | --- |
| M0 | Implemented; local software checks pass | Initial push blocked by host destination policy; GitHub CI has not run |
| M1 | Active from 2026-11-02; fixed deadline 2026-11-16 18:30 CET | Action mapping, frozen inventory, sandboxed transport/identity/telemetry/reversible-change proof |
| M2 | Session/discovery integrated; final offline review in progress | Actual reconnect/timing, cancellation and workflow hardware evidence; M1 A/B |
| M3 | Snapshot-driven feature UI under integration; unverified controls disabled | Captured hardware-verified drivers for all required actions |
| M4 | Blocked | EQ/gesture/case proofs, bounded advanced investigations |
| M5 | UI, preferences, notifications, icon and synthetic UI tests implemented | Passing UI execution, complete required feature behavior, accessibility and signed hardware evidence |
| M6 | Developer ID artifact signature verified; release disabled | Reusable signed build on normal host, notarization, universal archive, VM/hardware acceptance |
| M7 | Post-v1; not started | AA/P4 codecs, GATT, adverts and experimental drivers |

The underlying GuardedSession retains a single transaction lease, rejects busy
callers, does not retry, and closes on unresolved completion. The new offline
DeviceSession/scheduler layer owns snapshots and queued work above that boundary.
No NV
transactions or relay response unwrapping are enabled. Settings confirmation is
limited to the bounded mode proof above. The shared named runner validates the
same captured telemetry; normal UI state is mirrored from DeviceSession.
Mac GATT and authentication remain unverified. Compilation is not evidence of
Bluetooth access or transport feasibility.

The first private iPhone trace now has an
[offline structural report](protocols/captures/session-001.md): RACE framing,
GATT over Classic Bluetooth, and two identical candidate initialization
sequences. After the profile was reinstalled, live capture worked alongside the
official app. The [session 003 report](protocols/captures/session-003.md) adds a
known audible mode change and resulting mode reports. The session 005 and
Mac mode reports add limited Ambient proof; full mode support, PID identity
and safe general compound-write semantics remain unverified.
The [session 004 report](protocols/captures/session-004.md) adds
matched battery readings and captured firmware strings. FEATURE_PARITY.md
is still a draft. The [Mac read report](protocols/captures/mac-read-test-001.md)
records successful sandboxed RFCOMM telemetry on this baseline; the CLI, identity
and reversible-change gates remain pending.

A Developer ID Application certificate/private key and Apple's G2 intermediate
are installed. An explicitly selected keychain produced a timestamped universal
artifact with Hardened Runtime; strict signature/entitlement/Apple-anchor checks
passed. The agent's empty default keychain search still prevents Xcode identity
discovery. Notarization, permission persistence and signed hardware tests remain
unverified; see VERIFICATION.md for the exact artifact and host limitations.
Observed: Xcode 27.2,
Swift 6.4.2, arm64, tshark and PacketLogger present.

Do not record outcome C before the 14-day clock actually starts/expires. Missing
prerequisites do not establish impossibility. Record start/deadline in M1_RUN.md.
Release automation rejects tags until acceptance.json is backed by evidence.
