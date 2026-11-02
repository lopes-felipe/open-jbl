# Capturing Tour Pro 3 traffic

Use your own paired Tour Pro 3 and iPhone. Keep raw traces, names, addresses,
serials and personalization data under gitignored research/. Never commit vendor
binaries, extracted code, secrets or hearing/profile payloads.

## Preparation

The logging profile enables Bluetooth diagnostics on the iPhone. Download
**Bluetooth for iOS/iPadOS**, together with its Instructions, from Apple's
[Profiles and Logs](https://developer.apple.com/feedback-assistant/profiles-and-logs/?platform=ios).
Follow those instructions to install the profile.

PacketLogger is the Mac application that records and displays the trace. Download
**Additional Tools for Xcode** through Apple's
[Bluetooth developer page](https://developer.apple.com/bluetooth/) and open the
included PacketLogger app. Connect/trust the iPhone, then use File → New iOS Trace.
Apple demonstrates this workflow in its
[Core Bluetooth walkthrough](https://developer.apple.com/videos/play/wwdc2019/901/).
UI wording/logging availability depend on the installed tools/iOS.
If tracing is unavailable, record the prerequisite; do not invent evidence.

On the first local attempt, the official app lost control while audio still
worked. After basic recovery checks failed, removing the logging profile and
restarting the iPhone restored app control. The cause is not isolated. The
profile was then removed while the saved trace was analyzed. A later reinstall
allowed working live capture alongside the official app; the original failure
is not consistently reproducible. See the
[session 001 report](protocols/captures/session-001.md).

A follow-up without the profile opened a Live trace but recorded zero HCI/ACL
packets during audible mode changes. The trace was stopped. Profile-free
PacketLogger capture has therefore not been established on this phone.

### On-device recording as a separate test

Apple also describes collecting a Bluetooth packet log inside an iPhone
sysdiagnose, then opening that log in PacketLogger afterward:
[WWDC19 developer-tools walkthrough](https://developer.apple.com/videos/play/wwdc2019/901/?time=1115).
This uses the Bluetooth logging profile too; it is not a profile-free workaround.
Whether the official app works in this configuration on the tested phone is
unknown.

Before another capture, separate on-device recording from live USB streaming:
quit PacketLogger, disconnect USB, reinstall the same verified Apple profile,
restart the iPhone and check official-app control first. If app control fails,
remove the profile and restart to restore the baseline; do not keep repeating
the test. If control works, record one known change and its reversal, collect
a sysdiagnose using Apple's matching instructions, and retrieve the Bluetooth
packet log locally. A full sysdiagnose contains unrelated diagnostics; only the
Bluetooth trace is relevant to this project. Keep diagnostic archives private.

Record app version, region, iOS, earbud and case firmware in FEATURE_PARITY.md.
When hardware and tools are ready, set M1_RUN.md's start and fixed 14-calendar-day
deadline. Android-only actions remain not inventoried without an Android device.

## One change at a time

Create research/log.md with time, screen/action, before/after values, bud/case
state, persistence, audible result and trace filename. Capture:

1. Fresh official-app initialization, identity and versions.
2. All batteries/charging, docked and missing-partner cases, unsolicited touch/case
   changes, refusals and side effects.
3. All modes, min/mid/max levels, adaptive ANC, voice prompts, audio quality,
   auto-off, low-volume EQ, Smart Talk, Silent Now, auto-play/pause, Hi-Res.
4. Every preset and five curves: flat; +6 dB at 32 Hz; −6 dB at 1 kHz;
   +3 dB everywhere; a random curve with every gain recorded.
5. Every gesture choice per bud, all case settings including time sync.
6. Spatial/head tracking, Personi-Fi toggle, source list, VoiceAware if present,
   and Find My Buds start/stop with safe cancellation points.

Do not ring buds while wearing them. Record confirmation/precondition screens,
preserved unrelated fields and authoritative resulting state. A transport ACK
does not confirm a setting.

## Offline extraction

~~~sh
scripts/extract-race.sh research/session.pklg research/session.tsv
swift run jbl-probe decode research/session.tsv
~~~

TSV fields: frame.time_relative, hci_h4.direction, btl2cap.cid, btatt.opcode,
btatt.handle, btatt.value, btspp.data, btl2cap.payload. Validate ATT handles,
RFCOMM streams and lower-layer headers in PacketLogger/tshark. Decoder prefers
ATT, then SPP, then L2CAP per row and isolates direction/CID/handle streams.
Raw L2CAP sync matches can be false positives. Check action timing and full
traffic. Automatic decoding never enables a command.

When a mid-connection trace lacks ATT discovery context, a complete raw-L2CAP
Write Command (52) or Notification (1B) containing exactly one RACE frame is
labelled ATT-candidate with its handle. This is envelope recognition only;
service and identity remain unverified. Partial, concatenated or trailing-byte
envelopes are not classified as ATT candidates.

If observed dynamic CIDs carry ATT but the trace lacks negotiation, use explicit
offline overrides to recover concatenated and partial RACE messages:

~~~sh
scripts/extract-race.sh --att-cid 0x0043 --att-cid 0x050a \
  research/session.pklg research/session-with-context.tsv
~~~

Those CIDs are examples from session 004, not device constants. Validate the
channel envelopes first. The override establishes neither service nor identity.
It accepts only hexadecimal CIDs and changes no device setting.

The direction column uses H4 direction when available. For native PacketLogger
captures with no H4 pseudoheader, ACL record types 02/03 are normalized to
sent=0/received=1 in the same column. Other unknown directions remain empty.
Keep capture timestamps as recorded; correlate actions against the private log
and check clock offsets before interpreting wall-clock times.

Extraction publishes its private TSV only after tshark succeeds and never
overwrites an existing file or symlink. A failed extraction can be retried with
the same output path.

Run the capture-tool regression tests with tshark installed:

~~~sh
python3 -m unittest discover -s Tests/ScriptTests -v
~~~

These tests generate synthetic HCI traffic to check the real tshark field names
and extraction failure behavior. They are not device evidence.

## Reviewed fixtures and operations

Establish exact ID/subcommand/argument shape, firmware applicability, valid
ranges, preconditions, side effects, completion/read-back and abort behavior.
Add sanitized fixtures under Tests/JBLKitTests/Fixtures/tourpro3/:

~~~text
# provenance: official-app capture; local SHA-256 and action-log reference
# app: version / region
# firmware: earbud / case version
# hardware: pending or verification result
> complete captured command in hexadecimal
< complete captured reply in hexadecimal
< complete captured authoritative state in hexadecimal
~~~

This is a format example, not evidence. Replace addresses with
11 22 33 44 55 66 and serials with SERIAL0000000000. Remove personalization
payloads entirely. Keep research/denylist.txt with one real name, serial, address
or host CRC per line. Run scripts/check-fixtures.sh --require-denylist before
committing, then manually review. The checker never prints matched secrets.

Only then add the exact typed spec, decoder, membership and byte-for-byte fixture
tests. No dynamic specs, arbitrary opcodes, standalone reload or send-hex path.

Adding fixture files alone does not make the current probe or Link Test ready for
a reversible write. Captured identity/firmware decoders, authoritative read-back
and the sandboxed test sequence must also be implemented within M1. Identity and
firmware policy flags must come from that verification.

Before SDP/open, verify selected paired address and existing Classic ACL. Resolve
Airoha SPP through SDP, never a guessed channel. Document the OS race between
guard and call and prove late-open teardown. No openConnection. GATT requires a
separate Mac transport proof after RFCOMM fails. ATT can run over Classic
Bluetooth; LE pairing still needs the explicit Try LE control action.

### Mac Bluetooth permission

Audio connection and application Bluetooth permission are separate checks.
The probe explicitly requests adapter status before listing devices or acquiring
a reviewed operation's link. Denied access is an error, not an empty-device
result. Plain list and offline decode do not request Bluetooth permission.

On this host, macOS reports the Tour Pro 3 connected, but the agent-launched
probe reports Bluetooth access denied. The privacy pane has no OpenJBL/probe
entry in the user's screenshot. No SDP or channel open was attempted. The
next check is launching the signed sandboxed app directly from Finder, using
Inspect Paired Devices or Settings → Request Bluetooth Access / Refresh and
responding to macOS's permission prompt. That check subsequently passed for the
app, including paired-device inspection and cached Airoha SPP resolution.
Two explicit captured read tests then passed over sandboxed RFCOMM. The
agent-launched CLI remains denied. See the Mac read report for limits.
Rebuilding an ad-hoc signed app presented another permission prompt on this host.
Do not reset privacy databases or
remove app entitlements to bypass this failure.

Probe and sandboxed Developer → Link Test must read captured liveness/battery and
make one reversible change with matching state. Verify restart/reconnect,
competition, sleep and no paging before outcome A/B.
