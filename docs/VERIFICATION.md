# Local verification — 2026-11-02

Host: arm64, Xcode 27.2, Swift 6.4.2. Sandboxed Mac telemetry and a bounded
Ambient change passed; ANC's change contract and remote CI remain unverified. Official-app captures are
reported separately below.
A Developer ID Application certificate and its matching private key are
installed. Apple's G2 intermediate certificate was missing and has been imported
from its official certificate-authority page after chain verification. An
explicit-keychain signing run succeeded; details and limits are below.

## Current offline integration batch

The integrated session, app and shared validation runner passed 120 Swift tests
in ten suites, an arm64 Debug build-for-testing, and a universal arm64/x86_64
Release build. The latest complete package run includes final cancellation,
ownership and visible battery-polling fixes. An earlier fake-clock test hung;
its cancellation/registration race was fixed before this successful full run.

Completed tooling checks for this batch: 36 script regressions (seven using
actual tshark; fourteen isolated signing/build checks; seven release-gate checks;
eight UI-runner checks),
five-fixture hygiene with the private denylist, and Bash 3.2 syntax.
The actual incomplete release attestations remain rejected. Mock signing tools
exercise failure behavior without configuring or proving a real certificate.
No new hardware operation or acceptance test was performed for this batch.

A focused ten-test validation-runner check subsequently passed, including a
regression that a competing runner cannot close an already-owned connection.
The source privacy scan found no private identifiers or credential material;
zero-padded Xcode object identifiers were reviewed as substring false positives.

The universal Xcode Release artifact was explicitly re-signed with Developer ID,
timestamp, Hardened Runtime and App/OpenJBL.entitlements. Strict signature,
required sandbox/Bluetooth/file entitlements, Apple's anchor/Developer-ID leaf
OID requirement, and separate arm64/x86_64 architecture checks passed.
Its executable SHA-256 is
5a485be3a07bdce4447a30a7c1855acb704f0e4e2f105d83d033324a379a3c10.
An initial direct re-sign omitted entitlements; the artifact was rebuilt and
re-signed with the declared entitlements before recording these passing checks.
This artifact is not notarized and has no new hardware acceptance.

This agent's default keychain list remains empty. Xcode therefore cannot select
the Developer ID certificate through its default search, although direct
codesign with the explicit login keychain succeeds. This host limitation does
not justify changing global keychain search lists or trust overrides.

Actual XCUITest execution was attempted with scripts/check-ui.sh. The runner
could not launch: LaunchServices error -54 reports this process lacks allow
lsopen. The failed xcresult and summary are retained locally under
build/UITests/Results. No UI runtime pass is claimed. The Developer-ID-signed
sandboxed self-test likewise exits with SIGTRAP before main. CI now runs the
actual UI tests and retains results; remote success must be observed separately.

The initial source commit was prepared locally. Its first push to the existing
GitHub remote was rejected by the host's enterprise destination policy.
No remote CI run exists. Repository approval must be resolved through the
organization's security process; no alternative upload path was attempted.

The offline capture audit reproduced 148/259/387/1,005 reviewed frames for
sessions 001/003/004/005. These are coverage counts, not newly enabled specs.
See OPERATION_EVIDENCE.md for the consolidated protocol coverage.

## Earlier verified builds

| Check | Result |
| --- | --- |
| Swift package build | Passed with --disable-sandbox |
| Swift Testing suite | Passed; 76 tests in seven suites |
| Capture extraction regression suite | Passed; seven tests using actual tshark with synthetic HCI/PacketLogger traffic |
| First private iPhone trace, offline analysis | 148 exact ATT RACE frames; independent packet parsing agrees with Swift decoder metadata; operations and Mac transport remain unverified |
| Session 003, action-associated trace | 259 exact ATT-wrapped candidates cross-checked; ANC/Ambient fixture and passive report decoder tested at every byte split |
| Session 004, initialization | 387 reassembled RACE frames cross-checked; fixture bytes verified; passive battery/firmware decoders and correct 5D/role-offset matching tested |
| Session 005, mode profiles | 1,005 reassembled frames cross-checked; seven fixture frames equal source; distinct Ambient/ANC readback profiles tested |
| arm64 Debug Xcode app build | Passed |
| arm64 + x86_64 Release Xcode app build | Passed; lipo confirms both |
| codesign verification and sandbox/Bluetooth/file entitlements | Passed for Debug and Release |
| Probe list | Five reads and two guarded research mode operations |
| Probe list --devices | Bluetooth access denied in the agent process; now reports the denial instead of silently returning no devices |
| Probe uncaptured read | Rejected before Bluetooth |
| Fixture hygiene | Five captured fixtures; private identifier denylist enforced |
| Release evidence checker | Correctly rejected incomplete gates |
| Sandboxed --self-test runtime | Blocked by this host before app code |
| Negative self-test without entitlements (temporary copy) | Correctly returned passed=false and missing-entitlement checks |
| Bluetooth/sandbox hardware access | Passed through Finder-launched app: connected device, cached Airoha SPP/channel, two complete RFCOMM read runs |
| Developer ID, notarization, VM install, real UI and reconnect acceptance | Not tested |

Host commands must add -IDEPackageSupportDisableManifestSandbox=YES to xcodebuild
and OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'. These flags affect package
and macro subprocesses, not app entitlements. Default CI keeps compiler sandboxing.

Direct execution of the actual sandboxed app exits with SIGTRAP in
_libsecinit_appsandbox before main. LaunchServices also rejects launch with error
-54. The sandboxed self-test is therefore **not passed** locally. A scratch copy
with an empty entitlement dictionary executes the JSON self-test and correctly
fails. The canonical app's sandbox was not removed to manufacture a passing result.

GitHub CI includes relocated sandboxed self-test execution and entitlement checks.
It still needs an actual run outside this host. No Intel execution is claimed.

During the first Mac transport preparation, the user and system_profiler both
reported the Tour Pro 3 connected. The probe's explicit CoreBluetooth permission
check returned unauthorized. Its previous paired-device lookup had silently
returned no candidates. The CLI now checks permission before device enumeration
or a permitted operation's acquisition. Offline commands remain offline.
The original privacy-pane screenshot contained no OpenJBL/probe entry.
Direct Finder launch and permission approval subsequently worked for the
sandboxed app; the agent CLI remains denied. Removing the delegate's startup
activation-policy override made the visible app inspectable. Cached SDP resolved
channel 21. Two explicit read tests returned case 5.7.0 and agent/partner
32/24%, then 31/24%, closing the control channel after each.
See protocols/captures/mac-read-test-001.md. No settings were changed.

The subsequent four-read run at 19:54 CET also returned ANC through the captured
0901/module-5 read, with case 5.7.0 and agent/partner 26/21%.
No earbud firmware was passively observed. The exact captured 1C07 firmware
query was then explicitly approved by the user as a narrow exception.
The Mac query returned 6.0.1 at 20:04 CET. Tests prove other payloads/specs/models
and every wrapped form remain blocked. See protocols/firmware-query-review.md.

The subsequent mode-test build derives verification from the live transport
binding and successful version query, rather than trusting caller flags.
Test Ambient was audible and a separate fresh read returned Ambient. Its
complete state comparison was unconfirmed because an opaque field differed;
Test ANC then refused before writing because its baseline no longer matched.
This is not a confirmed round trip. See protocols/captures/mac-mode-test-001.md.

Session 005 then proved that the final readback byte is 06 in Ambient and 05
in ANC, repeated three times each. After requiring exact mode-specific profiles,
the rebuilt sandboxed app confirmed Ambient with matching notification and fresh
readback; the user heard it. ANC's change still failed replyNotSuccessful.
A separate read returned ANC and the user heard ANC. No success is assigned
to that failed transaction. See protocols/captures/mac-mode-test-002.md.

Review follow-up: the provided reviewer notes reported ongoing checks, with no
specific defect findings to accept or reject. Rechecking confirmed all eight
tshark fields exist, fixture hygiene passes and the incomplete release gate fails.
Independent inspection found and fixed unbounded duplicate completion storage
and partial TSV files left by failed extractions. Regression tests cover both;
capture-tool tests also run in CI with tshark installed.
