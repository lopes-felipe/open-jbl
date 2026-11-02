# Condensed delivery: offline implementation before grouped hardware work

The user approved the original v1 feature boundary, up to three parallel
implementation workers, and grouped validation. The latest direction is to
finish all possible offline code first and run the hardware sessions afterward;
do not schedule appointments or request per-setting hardware checks during
routine development. The user has a paid Apple Developer account and authorized
local signing setup; installed signing credentials must still be verified.

This changes work ordering, not protocol authorization or acceptance. Missing
capture-backed operations remain disabled. The approved direct 1C07/00 firmware
query replaces uncaptured 0301 for M1 liveness; the existing M1 deadline and all
other release gates remain unchanged.

## Work ownership and sequence

1. **Integration lead:** signing setup, shared guarded interfaces, named suites,
   structured diagnostics, code review and integration. Only this lead performs
   hardware actions after the offline batch is ready.
2. **Session worker:** state ownership, snapshots, scheduler, intents,
   cancellation, bounded recovery, leases and guarded discovery.
3. **App worker:** one AppModel stream consumer, functional views/settings,
   feature availability, local presets, notifications and diagnostics UI.
4. **Evidence/tooling worker:** offline capture audit, operation coverage,
   exhaustive capture checklist, CI and reusable validation scripts.

Workers may implement and test independent software concurrently. Integrate
shared contracts first; no worker invents uncaptured payloads to fill a feature.
Complete software behavior, disabled states and replay fixtures for everything
that can be proven offline. Record remaining capture-dependent drivers explicitly.

Use three integration batches: everyday session/status/sound; remaining device
features; UI hardening/release preparation. These are review boundaries, not a
reason to present a smaller preview as the requested v1.

## Validation and the next hardware checkpoint

- Per edit: relevant focused tests and fixture checks.
- Per integration batch: scripts/check-fast.sh, then the universal signed
  scripts/check-integration.sh artifact, entitlements and relocated self-test.
- Before hardware: one build hash, functioning permissions, source-defined
  suite list, stage diagnostics and the complete numbered capture checklist.
- Hardware: execute the three groups in GROUPED_VALIDATION.md; perform defect
  retests only after an offline regression and fix.
- Release candidate: original Developer ID/notarization, clean-install,
  reconnect/wake, audio coexistence, redaction and matched battery gates.

No suite accepts arbitrary opcodes or raw bytes. Suites stop affected writes on
unexplained mismatches, preserve failed reports, release control, and never
silently restore/retry/resume an action. Audible observations remain separate
from protocol outcomes.

## Canonical records and reporting

FEATURE_PARITY.md owns the frozen action inventory; acceptance.json owns release
attestations. OPERATION_EVIDENCE.md owns wire-evidence coverage. Keep individual
capture reports as historical evidence, not competing status inventories.

Report implemented and hardware-verified required actions as separate counts
once the action inventory is frozen. Until then, report the seven enabled
research specs, five fixtures and actual bounded hardware proofs without
inventing a required-action denominator. Each integration update names blockers,
next build/session prerequisites and any change in the effort estimate.

The original 12–18 working-day estimate assumes obtainable protocol evidence
and signing prerequisites; it is not a completion guarantee or appointment.
Completion still means the entire frozen required inventory and original
release gates pass. Unresolved protocol evidence remains a visible blocker.
