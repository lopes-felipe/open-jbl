# Session 005: distinct listening-mode readback profiles

Date: 2026-11-02. App 5.38.3, Germany; earbuds 6.0.1, case 5.7.0.
The user initialized the official app in Ambient, changed to ANC, heard ANC,
and initialized the official app again. The stopped private trace contains
7,874 records. Its hash and source file remain in research/log.md.

The observed ATT envelopes use CIDs 0043/050A, handles 0053/0055, HCI connection
000B. These are capture-specific values, not transport constants. Independent
bounded reassembly and the Swift decoder agree on the ordered metadata of all
1,005 recovered RACE frames. The seven fixture frames equal the source bytes
and directions exactly. Unknown payloads remain private.

| Exchange | Packets | Payload |
| --- | --- | --- |
| Ambient module-5 read | 1333 / 1338 | request 05 00; response 05 00 00 0A 07 00 06 |
| Ambient repeat reads | 1423 / 1427; 1682 / 1683 | identical response |
| ANC change | 1748 / 1749 / 1753 | command 00 0A 01 00; reply 00 0A 01 00 00 00; notification 05 00 00 01 07 00 |
| ANC module-5 read | 2491 / 2505 | request 05 00; response 05 00 00 01 07 00 05 |
| ANC repeat reads | 2587 / 2589; 2848 / 2850 | identical response |

The last readback byte differs consistently with mode on this baseline. Its
meaning remains unknown. It is neither treated as an acknowledgement status
nor required to remain equal across modes. The bounded research test accepts
only the complete captured ANC and Ambient profiles before a write, and
requires the exact target profile after it. Other opaque values still fail.
No general level encoder or argument range is inferred.

The [new Mac test](mac-mode-test-002.md) confirmed Ambient with this correction.
ANC was audible and independently read back, but its change reply/notification
check failed. That discrepancy is still open; a full round trip is not passed.
