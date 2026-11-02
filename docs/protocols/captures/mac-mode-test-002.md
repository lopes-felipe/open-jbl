# Mac mode test after capturing both readback profiles

Date: 2026-11-02, approximately 20:35 CET. Sandboxed universal ad-hoc Release
build; arm64 execution. The user closed the phone JBL app, wore both earbuds,
and approved Bluetooth access for the rebuilt app.

Session 005 establishes distinct complete readback profiles:
ANC 05 00 00 01 07 00 05 and Ambient 05 00 00 0A 07 00 06.
The mode proof now checks each mode against its own captured profile. It still
requires live transport identity, a successful 6.0.1 version query, a fresh
baseline, at most one captured write, the exact reply and mode notification,
and a fresh target readback. A single transaction lease covers these steps.

## Results

1. Test Ambient reported “Mode changed; notification and fresh readback agree”
   and “Confirmed Ambient from the device.” The channel then closed.
   The user confirmed: “Yes, Ambient is audible”.
2. The explicit Test ANC opened a new channel, then stopped with
   replyNotSuccessful and closed. It did not retry. This means the reply or
   notification failed its exact captured contract; the existing error does
   not identify which check failed. The reply bytes were not recorded.
3. A separate five-read run returned earbuds 6.0.1, case 5.7.0, mode ANC,
   agent 17% and partner 11%. The channel closed.
4. The user confirmed: “Yes, ANC is audible”.

Ambient passes this bounded sandboxed mode proof. ANC was audible and separately
read back, but its change transaction is **not verified**. A subsequent read
does not retroactively turn a failed transaction into success. No automatic
restore or replay occurred. The earbuds were left in ANC with no control link
held; further sound checks were stopped for this session.

Next evidence needed is a Mac-side capture of the ANC reply and notification
to explain the contract mismatch. Do not relax the check from delivery or sound
alone. Unsandboxed probe validation, PID decoding, inventory freeze
and other M1 acceptance evidence remain outstanding. No M1 A/B or release gate
is marked passed.

The subsequently approved M1 amendment uses the captured direct 1C07/00 query
for liveness. 0301 is no longer a prerequisite and remains disabled unless
captured. That amendment does not resolve this ANC transaction discrepancy.
