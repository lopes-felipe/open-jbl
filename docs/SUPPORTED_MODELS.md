# Supported models

| Model | Protocol hypothesis | Current support |
| --- | --- | --- |
| JBL Tour Pro 3 (20F2, case 20FD) | Airoha RACE; RFCOMM expected | Research target; no verified telemetry or control |
| Harman AA | Excelpoint BLE | Planned experimental, M7 after v1 |
| Harman P4 | Excelpoint BLE | Planned experimental, M7 after v1 |
| Other Airoha JBL | Unknown | Unsupported |

Catalog “verified” means capture-only policy for this target, not a hardware
verification claim. Names/SDP are discovery hints. PID/address identity must pass
before writes. Unknown firmware gets captured firmware-independent reads only.

Minimum macOS 14. Local checks are arm64; Intel and macOS 14 VM/hardware acceptance
remain untested. Releases target arm64/x86_64. The probe is excluded from the DMG.
