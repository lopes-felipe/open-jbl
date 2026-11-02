# Release procedure (disabled until M1–M5 pass)

## Reusable development validation

Run `scripts/check-fast.sh` for package, fixture and capture-tool checks;
run `scripts/check-integration.sh` at an integration boundary. The latter
builds one universal Release artifact at `build/Validation`, verifies the
signature/entitlements and both architectures, runs the relocated sandboxed
self-test, and prints the executable SHA-256 for session reports.

Local integration builds require a usable **Developer ID Application**
certificate and private key in the user's keychain. The validation script
discovers a single identity; if several exist, set `OPENJBL_SIGNING_IDENTITY`
to its exact certificate label or SHA-1. The certificate fingerprint is a
selector, not an exported private key. The script blocks before building if
the identity is unavailable or ambiguous; it never silently signs ad-hoc.
The paid account alone does not establish a local signing identity.

If the normal identity list omits a usable certificate, explicitly select its
existing keychain with OPENJBL_SIGNING_KEYCHAIN. The script then matches the
certificate by SHA-1 and verifies its signing trust before building. It does
not change keychain search lists, trust overrides or fall back to ad-hoc signing.
Xcode must still be able to discover the selected identity in its own context.
The resulting artifact must pass Apple Developer ID anchoring, exact leaf
certificate, timestamp, runtime, entitlement and certificate-chain checks.
If an intermediate is missing, obtain it only from
[Apple's certificate-authority page](https://www.apple.com/certificateauthority/).

CI explicitly uses `scripts/build-validation.sh --ci-ad-hoc` without
distribution credentials. That flag is rejected outside CI. CI results are
software checks, not Developer ID hardware evidence.
scripts/check-ui.sh runs the five synthetic window/menu presentation tests on
a graphical Mac and preserves the xcresult and summary. It fails a build-only,
empty, skipped or unsuccessful test run. The integration script runs it after
the universal build/self-test, and CI uploads the UI results even on failure.

On this restricted agent host, `OPENJBL_HOST_RESTRICTED=1` adds only compiler/
manifest sandbox workarounds. App entitlements remain intact. If the actual
sandboxed self-test cannot start, integration remains failed; do not remove
entitlements or count a scratch executable as the validation artifact.

Open `scripts/probe-terminal.command` from Finder/a normal user-launched
terminal for the probe's initial Bluetooth permission/device-list check.
The launcher requires a terminal and never changes privacy settings, signs a
binary, pairs or opens a control channel. Permit a system prompt manually.
Use the named `validate` suites shown by probe help after permission works;
keep device identifiers and raw captures out of shared reports.

Keep the bundle identity `io.github.lopesfelipe.OpenJBL` stable. Verify
permission persistence over two actual signed rebuilds before claiming it;
Developer ID signing is not a promise that macOS will retain consent.

The existing GitHub remote is `lopes-felipe/open-jbl`. CI supports
`workflow_dispatch` once this workflow is pushed. No remote run, signing
configuration or upload is implied by the checked-in workflow.

## Release gate and distribution

Run scripts/check-release-gates.py first. The committed acceptance.json currently
fails deliberately. Each true field is a manual attestation requiring an evidence
report for the release candidate, not an automatic certification. Preserve the
frozen inventory and all applicable v1-required rows.

Before a v* tag, verify on sandboxed Developer ID builds on macOS 14 and the
current release (arm64): all required features; 30 reconnect and 10 sleep/wake
cycles; no paging; coexistence/audio/calls/multipoint/case USB; refusal/retry;
redacted exports; matched two-hour battery-drain runs; clean VM installation and
self-test from /Applications. Publish proof-gated failures and out-of-scope
actions as gaps. Intel is built, not tested.

The GitHub release environment requires:

| Secret | Format |
| --- | --- |
| DEVELOPER_ID_P12 | Base64-encoded Developer ID Application certificate/private key |
| P12_PASSWORD | Import password |
| NOTARY_KEY_ID | App Store Connect API key ID |
| NOTARY_ISSUER | API issuer ID |
| NOTARY_KEY_P8 | Raw multiline .p8 contents |

Never put secrets in source, shell history or logs. release.sh uses a temporary
keychain, restricted temporary files, and cleanup on exit. It archives an arm64
and x86_64 app using Xcode, checks signature/entitlements/architectures/self-test,
notarizes/staples the app, creates an hdiutil DMG containing only the app and
Applications link, then signs/notarizes/staples the DMG.

The workflow runs on v* tags and publishes the DMG and SHA-256 with the parity
report. The probe and research files are never shipped. Run this workflow only
after the evidence gates; current credentials and acceptance are missing.

Notarization cannot replace the clean-VM Gatekeeper and actual hardware tests.
Do not claim GitHub CI or a release succeeded without its actual run result.
