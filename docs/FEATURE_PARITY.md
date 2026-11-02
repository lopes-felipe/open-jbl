# Official-app parity baseline

**Draft, not frozen. No installed-app inventory supplied.** User-reported on
2026-11-02 after connection recovery: iPhone app 5.38.3; App Store region Germany;
earbud firmware 6.0.1; case firmware 5.7.0. Captured version strings in session
004 match these values; PID/address identity remains unverified. Inventory date: unset.
Android-only actions: **not inventoried**. Full parity is not claimed.

Rows below are approved intended scope, not observations of the installed app.
During M1 split these into actual screen/action rows, recording preconditions,
side effects, persistence, cross-feature limits, fixtures and hardware status.
No required row may silently become a gap to pass release.

| Action | Class | Evidence / hardware | Blocker |
| --- | --- | --- | --- |
| Identity, audio/control status, batteries/charging, versions | v1 required | Session 004 fixture; two sandboxed Mac RFCOMM tests read case 5.7.0 and agent/partner batteries; official-app comparison within one point; see Mac read report | PID identity, side mapping, charging/dock state, remaining telemetry and functional status UI |
| ANC, Ambient, TalkThru, Off and levels | v1 required | Session 003/005 fixtures; sandboxed Ambient passed exact notification/readback and audible check; ANC audible and separately read, but change contract failed | ANC reply/notification mismatch, remaining modes/levels and general driver |
| Adaptive ANC/calibration | proof-gated | None / unverified | Proprietary procedure |
| EQ presets, on/off, named local presets | v1 required | None / unverified | Capture |
| Custom ten-band EQ | proof-gated, two working sessions | None / unverified | Exact coefficients/packing |
| Gestures | v1 required | None / unverified | Exact bounded NV transaction |
| Prompts, auto-off/play-pause, Smart Talk, Silent Now | v1 required | None / unverified | Capture/preserved fields |
| Low-volume EQ, audio quality/Hi-Res | v1 required | None / unverified | Capture |
| VoiceAware, rename, case language/shortcuts | proof-gated | None / unverified | Capture if present |
| Spatial/head-tracking toggles | v1 required | None / unverified | Capture |
| Host spatial rendering/recentering | documented gap | None / unverified | Mac API |
| Personi-Fi toggle; preserve existing profile | v1 required | None / unverified | Capture |
| Hearing/fit tests and profile generation | documented gap | None / unverified | Proprietary procedure/calibration |
| Case brightness, timeout, tap-to-wake, 24h, time sync | v1 required | None / unverified | Capture |
| Case wallpaper, notifications, lock/wake flows | documented gap | None / unverified | Transfer/cancellation/Mac API |
| Connected sources list | v1 required, read-only | None / unverified | Capture |
| Multipoint, unpair, LE Audio, Auracast | documented gap | None / unverified | Protocol/Mac API |
| Find My Buds start/stop | v1 required | None / unverified | Safe exclusive cancellation |
| Relax Sound | documented gap | None / unverified | Legitimate content source |
| Versions and official support link | v1 required | Link implemented; case 5.7.0 and earbuds 6.0.1 read on sandboxed Mac | Functional status UI |
| Firmware download/install, reset | documented gap, out of v1 | Not implemented | Authentic source/separate design |
| Shopping, accounts, marketing | N/A | Excluded | — |

Missing transport telemetry remains a gap. Device-side LDAC never promises LDAC
from macOS. No driver, notification interception, cloud or analytics.
