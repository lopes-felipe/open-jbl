# OpenJBL

A native, offline macOS menu bar app targeting JBL Tour Pro 3 interoperability.
macOS 14+, Swift 6, Apple frameworks. No account, analytics, audio driver or codec.

**Current status: M1 hardware evidence plus offline session/UI integration.
Five captured reads passed
sandboxed Mac RFCOMM tests. A bounded Ambient change passed notification,
readback and audible checks. ANC's change contract remains unverified;
normal device controls are not ready.**
There is no claim of feature parity.
The [Mac mode report](docs/protocols/captures/mac-mode-test-002.md) records the
results and remaining ANC reply issue. The [Mac read report](docs/protocols/captures/mac-read-test-001.md) records the
actual results and remaining gate. The [capture report](docs/protocols/captures/session-001.md) records
RACE over GATT on Classic Bluetooth and the remaining evidence gaps. The M1
feasibility gate must pass before hardware capabilities or release readiness
are promoted. The latest implementation direction is to finish all possible
offline code and replay tests before grouped hardware sessions. Missing captured
operations stay disabled. A [captured ANC/Ambient exchange](docs/protocols/captures/session-003.md)
backs the exact two guarded research mode operations.
The [initialization report](docs/protocols/captures/session-004.md) adds passive
battery and firmware decoding, with matched user readings and sanitized fixtures.

OpenJBL is not affiliated with, endorsed by, or sponsored by JBL or Harman.
JBL is a trademark of its respective owner. No vendor art is included.

## Build and test

~~~sh
swift build
scripts/check-fast.sh
codesign --force --sign - .build/debug/jbl-probe
scripts/check-integration.sh  # local Developer ID certificate/private key required
~~~

Open OpenJBL.xcodeproj in Xcode to run the sandboxed app. Closing the window keeps
the menu bar app running. Settings requests Bluetooth access and lists already-
paired supported devices. Connect audio through macOS. OpenJBL never pairs,
calls openConnection, or changes audio routes. A Classic ACL does not establish
that this device is the current audio route.

If the host denies nested sandbox-exec, use swift build/test with
--disable-sandbox, and add -IDEPackageSupportDisableManifestSandbox=YES to
xcodebuild. For macro subprocesses on the same restricted host also pass
OTHER_SWIFT_FLAGS='$(inherited) -disable-sandbox'. These flags affect compiler
subprocesses; the app sandbox remains enabled. Xcode may disable Hardened Runtime
for ad-hoc signing; Developer ID release builds enable it. Normal CI uses the
default compiler and manifest sandbox.

The reusable integration build is universal, checks entitlements and a relocated
sandboxed self-test, and prints its hash. It blocks if local Developer ID signing
is unavailable; CI uses an explicit ad-hoc flag. A signed development build is
not a notarized distribution. Intel remains untested. See the
[signing/validation procedure](docs/RELEASING.md) for identity selection.

## Probe and captures

~~~sh
.build/debug/jbl-probe list
.build/debug/jbl-probe list --devices  # explicit passive inspection
.build/debug/jbl-probe validate list  # offline finite-suite inventory
scripts/extract-race.sh research/session.pklg research/session.tsv
.build/debug/jbl-probe decode research/session.tsv
scripts/check-fixtures.sh --require-denylist
~~~

The offline decoder prints only type, ID and payload length. Full captures remain
private. Decoding never enables an operation. There is no arbitrary opcode/hex
send option. Read/write commands use reviewed catalog names and the same guarded
send path as the app. Five named reads and two no-argument research mode tests
are enabled. Mode tests require active transport identity, a successful live
6.0.1 query, a captured state baseline and authoritative read-back. Other writes
and actions remain rejected. The single firmware-read blocklist exception was
[explicitly approved by the user](docs/protocols/firmware-query-review.md).

Launch with --developer-tools for the named telemetry, Ambient and ANC validation
suites. The app and probe share the same finite runner and guarded send path.
Suites retain stage-specific reports, keep human observations separate and
release control afterward. They never restore or retry a write automatically.
Use scripts/probe-terminal.command in a normal user-launched terminal for its
initial permission check; the agent process's Bluetooth denial is not a device
failure. Normal control UI does not enable an uncaptured feature.

- [Implementation status](docs/IMPLEMENTATION_STATUS.md)
- [Condensed delivery and offline-first sequence](docs/CONDENSED_DELIVERY.md)
- [Operation/evidence matrix](docs/OPERATION_EVIDENCE.md)
- [Grouped hardware checklists](docs/GROUPED_VALIDATION.md)
- [Capture procedure and timebox](docs/CAPTURING.md)
- [Feature parity baseline (not frozen)](docs/FEATURE_PARITY.md)
- [Safety boundary](docs/SAFETY.md)
- [Supported models](docs/SUPPORTED_MODELS.md)
- [RACE evidence report](docs/protocols/airoha-race-tourpro3.md)
- [Local verification and host limitations](docs/VERIFICATION.md)
- [Gated release procedure](docs/RELEASING.md)

No firmware updater, reset, wallpaper transfer, hearing test, Auracast controller,
or speculative gesture NV writes. A deferred feature remains a gap. Full parity
requires every applicable frozen-inventory action to pass hardware acceptance.

Our code is [MIT licensed](LICENSE). See [third-party records](THIRD_PARTY_NOTICES.md).
