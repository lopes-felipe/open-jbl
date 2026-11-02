# Grouped validation runbook

Implement and replay-test all possible software work before the next hardware
session. No calendar appointments are assumed. These are finite checklists,
not authorization to send uncaptured commands. The existing M1 evidence gates
and fixed deadline remain in force.

Use [OPERATION_EVIDENCE.md](OPERATION_EVIDENCE.md) for missing wire evidence and
[FEATURE_PARITY.md](FEATURE_PARITY.md) for the canonical inventory. Record each
session's build hash, signing identity type, app/region/firmware, initial state,
numbered results and remaining actions in one redacted report. A software test,
an audible observation and authoritative device state are distinct evidence.

## Session 1 — capture, inventory and feasibility

Prepare a charged set, trusted iPhone, working logging profile/PacketLogger,
one signed diagnostic build, user-launched probe and the numbered script. Do
not use the official app and Mac control simultaneously except the explicit
controller-competition test. Check increasing HCI/ACL counts before editing.

For each number below: record the initial value, action/time marker, visible
result, audible/physical observation, side effects, availability limits and
persistence after reopening the official app. Change one field at a time.
If the session stops, retain the exact next number and untested options.

1. **Mac proof:** phone app closed; already-connected Classic link only.
   Run named telemetry suite through the sandboxed app and user-launched probe.
   Capture the ANC transaction with stage diagnostics and a private Mac trace;
   compare baseline, ACK, notification and readback. Validate a reversible
   captured change without auto-retry. Save reports before another run.
2. **Acquisition guard:** release controls, disconnect using macOS, request a
   suite and verify no acquisition/page occurs. Reconnect manually. In a
   separate controller-competition check, reopen the phone app, record the
   actual refusal behavior, close it and explicitly Retry.
3. **Inventory:** record every official-app screen/action and all available
   choices. Freeze app 5.38.3, Germany, earbuds 6.0.1 and case 5.7.0 only after
   confirming the installed values. Android-only actions remain not inventoried.
4. **Fresh initialization/status:** new iPhone trace, force-quit/reopen app,
   device-information screen. Record L/R/case levels, versions and exact
   connection state. Capture both buds out, left docked, right docked, both
   docked and case charging/unplugged; record missing versus stale readings.
5. **Modes:** ANC → Ambient → TalkThru → Off → original mode, each audible.
   Capture all visible mode-specific levels at minimum, middle and maximum.
   Change modes using touch and case separately, with the app visible; record
   unsolicited update timing. Test the official app's docked-bud refusal.
6. **Adaptive ANC:** inventory toggle/calibration, start/completion/cancel only
   through the official procedure; record unavailable states and side effects.
7. **EQ presets:** record the complete preset list, select each once, capture
   EQ off/on, return to the original preset. Record interactions with Hi-Res,
   spatial, Personi-Fi and low-volume EQ.
8. **Custom EQ:** capture five ten-band curves with every displayed value:
   flat; +6 dB at 32 Hz only; −6 dB at 1 kHz only; +3 dB everywhere; random
   curve [−2,+1,+4,−3,+2,−1,+5,0,−4,+3] dB in displayed low-to-high order.
   If those exact frequencies/ranges are unavailable, record actual labels
   and limits instead of silently substituting. Save each apply sequence.
9. **Gestures:** inventory every gesture/action option. For left, then right,
   change each available gesture through every selectable action, one at a
   time; record groups that are mutually exclusive. Restore initial mapping.
   Capture partner-in-case behavior and reopening persistence.
10. **Calls/voice:** voice prompts off/on, every VoiceAware option if present,
    call-processing controls, voice-prompt language if present. Record any
    active-call prerequisite; do not invent a call result without a real call.
11. **Device controls:** auto-off disabled/enabled and every available interval;
    auto play/pause off/on; Smart Talk options and delay; Silent Now start,
    duration and explicit stop. Capture unrelated values before and after.
12. **Advanced sound:** low-volume EQ off/on, every quality choice, Hi-Res
    off/on, spatial modes and head-tracking off/on. Record forced resets,
    reconnects, mutually unavailable choices and any playback interruption.
13. **Personi-Fi:** capture toggle off/on with an existing profile and verify
    it is preserved. Do not generate a hearing profile or export its payload.
14. **Case:** brightness minimum/middle/maximum; every timeout; tap-to-wake
    off/on; 12/24 h; official time sync; every language/shortcut if present.
    Record per-setting initial value, case reachability and persistence.
    Inventory wallpaper/notifications as existing gaps; do not transfer assets.
15. **Sources:** read source/device list with phone and Mac connected, then
    one disconnected. Record displayed identities privately and list freshness.
    Do not unpair or mutate multipoint, LE Audio or Auracast.
16. **Find My Buds:** follow official warnings; earbuds out of ears. Capture
    left start/Stop, right start/Stop and both if supported. Capture explicit
    cancellation, permitted interruption and disconnect behavior. Never test
    ringing while worn. Safe cancellation is required before enabling a suite.
17. **Persistence and finish:** restore original settings through the official
    app, cycle case in/out and reopen once. Save/stop the trace, note remaining
    checklist numbers, and retain private source/hash/action log. Sanitize
    fixtures and analyze offline before any newly captured operation is sent.

The approved 1C07/00 query is M1 liveness. 0301 stays disabled unless captured.
Declare M1 A/B only after its independent identity/telemetry/reversible-change,
probe/sandbox, restart and no-paging evidence passes.

## Session 2 — integrated features

Use one signed integration build only after replay tests pass. Run each group
under one controlled acquisition; stop its affected sequence on an unexplained
mismatch. Preserve reports and reproduce defects offline before another build.

1. Status/sound: identity and separate audio/control status; L/R/case freshness,
   unknown/docked/charging states; versions; every mode and level; refusals;
   case/touch/phone reconciliation and timing.
2. EQ: every preset and toggle, named local preset persistence; custom curves
   only if the exact-byte/±1 LSB proof passed. Confirm audible results and
   case-in/out persistence.
3. Earbud controls: every inventoried gesture, prompt, playback, voice, spatial,
   quality, Hi-Res, Smart Talk, Silent Now and Personi-Fi toggle. Verify
   unrelated-field preservation and cross-feature constraints.
4. Case/sources: all required case controls, time sync and read-only source
   list. Confirm reported values and persistence without connection guessing.
5. Find My Buds: safe side selection/start/Stop, cancellation, disconnect,
   sleep, release and restart; never replay a prior action.
6. UI: panel/window agree on pending/confirmed/stale/busy/indeterminate;
   unavailable sections show reasons, unsupported sections hide. Check keyboard,
   VoiceOver, dark mode, notifications and explicit opt-in login behavior.

## Session 3 — release candidate

Use the Developer ID release candidate, macOS 14 and current macOS on arm64.
Keep Intel labelled untested. Preserve individual cycle timings and failures.

1. Thirty reconnect cycles: ready within 10 s in at least 9/10 of the milestone
   measurement set; record all 30 cycles, stale writes and leaked sessions.
2. Ten sleep/wake cycles: no resumed workflow, ready within 15 s in at least
   9/10; include Bluetooth off/on and verify its same recovery target.
3. Exercise controller refusal/explicit Retry, Release Controls without audio
   loss, device switch, cancellation mid-operation and 30 s idle release.
   No repeated opens/pages when disconnected or case closed.
4. Play music, make a real call, use phone multipoint and case USB audio while
   controlling; record any dropout. Cross-check touch/case/phone changes.
5. Copy/export diagnostics; scan private denylist, serial/name/address and
   reverse encodings. Unknown/private payloads must remain withheld.
6. Install notarized DMG on clean macOS 14; verify Gatekeeper, self-test from
   /Applications, required entitlements and actual Tour Pro 3 reconnection.
   Repeat relevant control checks on the notarized build.

### Matched battery sessions — separate elapsed-time experiment

Run three matched two-hour playback sessions: app absent, app hidden and UI
visible. Use the same audio, playback level, mode, starting charge and physical
conditions; record initial/final fresh levels and control-link activity. Allow
charging/setup time in addition to six hours of playback. A difference larger
than one reported battery step or two percentage points, whichever is greater,
requires a repeated comparison. A reproduced excess blocks release until fixed.

Release attestations stay false until actual evidence passes. A grouped session
reduces setup, not acceptance coverage.
