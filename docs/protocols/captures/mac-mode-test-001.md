# First guarded Mac mode test: audible, full comparison unconfirmed

Date: 2026-11-02. Sandboxed universal ad-hoc Release build. Both buds worn for
the sound check per user; iPhone JBL app closed. No release acceptance claimed.

## Preconditions and send path

The production session clears caller-supplied identity/firmware booleans.
After RFCOMM opens, it binds to the transport's copied selected paired address
and exact Classic name. This is the plan's temporary name fallback; the 0092
PID layout remains unmapped. The binding is cleared on disconnect/close and
rechecked before dispatch. Only the active successful captured firmware query
with version 6.0.1 permits a write.

The two research operations encode only complete captured requests from
session 003. They accept no arguments. A single session lease covers the
fresh mode read, at most one write, matching acknowledgement plus mode
notification, and a second fresh mode read. The test requires the captured
opaque baseline 07 00 05, and compares the entire post-read field set.
No generalized mode/level encoder exists.

## Observed outcome

1. Test Ambient passed the initial baseline and sent the captured Ambient
   request. Its matching reply and 5D state notification passed validation.
2. The fresh mode read failed the complete baseline comparison. The app
   reported ModeTestError.unconfirmed, closed control, and did not retry.
3. The user reported: “Yes, Ambient is audible”.
4. A separate read-only run returned Ambient, earbuds 6.0.1, case 5.7.0 and
   agent/partner 19/16%. Thus the mode field changed as requested; an opaque
   field differed. The exact differing field/value has not yet been recovered.
5. The explicit ANC restore attempt failed its initial baseline check, before
   any mode write. It reported baselineMismatch and closed the link.

The user subsequently restored ANC audibly through the official app and captured
both initializations in [session 005](session-005.md). The suffix is 06 in Ambient
and 05 in ANC. The [next Mac test](mac-mode-test-002.md) uses those exact profiles;
this report preserves the first attempt's outcome.

The actual Ambient write is a useful interoperability result. Full mode proof,
safe field handling, unsandboxed CLI verification and the remaining M1 gates
are still incomplete. No outcome A/B or release flag is marked passed.
