# Harman Protocol 4 (M7)

Deferred until Tour Pro 3 v1. No P4 encoder, reassembler, calibration, handshake,
GATT or driver. Blocklist helpers cannot send anything.

Future tests must calibrate bare/status-prefixed replies using GET 0004 and an
advertised PID, never shape alone. Ambiguous 00 00 04 00 02 00 0F 00 stops.
Honor security mode, raw-before-control subscriptions, 0007 handshake-only,
no GET 1F00, and maximumWriteLength − 8 chunks. No speculative Tour Pro 3 fallback.
