# Third-party references and dependencies

OpenJBL's own code is MIT licensed. This implementation is original; no code or
assets have been copied from the protocol reference projects below.

| Reference | Reported upstream licence | Use |
| --- | --- | --- |
| [3xa228148/wavebuds](https://github.com/3xa228148/wavebuds) | MIT | AA protocol and capture methodology |
| [ncr/omarchy-headphones](https://github.com/ncr/omarchy-headphones) | MIT | AA state and connection research |
| [AhmadRun/jbl-control](https://github.com/AhmadRun/jbl-control) | MIT | Feature inventory and risk research |
| [ffrafat/JBLControl](https://github.com/ffrafat/JBLControl) | MIT | Package/app separation; speaker commands excluded |
| [FajkPes/JBL-Headphones-App](https://github.com/FajkPes/JBL-Headphones-App) | No licence in the supplied plan | Facts only; no code or assets permitted |
| [davedumto/Hush](https://github.com/davedumto/Hush) | Apache-2.0 in the supplied plan | Transport reference; no adapted code |
| [saikiran9185/JBLControl](https://github.com/saikiran9185/JBLControl) | MIT in the supplied plan | SDP research; no generic channel fallback |
| [auracast-research/race-toolkit](https://github.com/auracast-research/race-toolkit) | Facts only | Envelope research |

These are reference records, not a licence audit or permission to copy. Before
adapting upstream code, record the exact commit and actual licence, retain its
copyright and required notices, and update this file. Include Hush's Apache
notice if any of its code is adapted. No vendor code, binaries or assets.

## Developer CLI dependency (not included in the app or DMG)

[apple/swift-argument-parser](https://github.com/apple/swift-argument-parser),
resolved in Package.resolved, is Copyright (c) 2020 Apple Inc. and the Swift
project authors. It is licensed under Apache License 2.0 with Runtime Library
Exception. Its original licence is available at
[LICENSE.txt](https://github.com/apple/swift-argument-parser/blob/main/LICENSE.txt).
The dependency is linked only into jbl-probe, which is not in the DMG.
