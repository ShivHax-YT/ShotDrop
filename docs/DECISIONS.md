# ShotDrop — Decisions

Judgment calls made without asking. `YYYY-MM-DD | decision | why | who`

2026-09-22 | M0 uses native SwiftUI MenuBarExtra and Settings scenes, Observation-backed preferences, and SMAppService.mainApp. No third-party dependencies. | Keeps the macOS 14 scaffold small and idle without timers. | implementor
2026-09-22 | Launch at login defaults off and changes only from an explicit settings action; the UI reflects Service Management status and approval/error states. | Registration is user intent, not a startup side effect. | implementor
2026-09-22 | M0 stores future capture preferences but clearly labels screenshot processing as unavailable until M1; no file watchers, clipboard writes, or folder creation at startup. | A usable shell must not imply a working screenshot pipeline or trigger premature privacy prompts. | implementor
2026-09-22 | Until a development team is configured locally, debug builds use ad-hoc signing. Actual login-at-login and TCC persistence remain separate system acceptance checks. | No signing team was provided; the scaffold can build and launch without credentials. | implementor
2026-09-22 | Keep M0's native menu and grouped Settings form; defer the design report's recent-item panel to M2. | M0 is a shell, and the inactive-processing explanation requires more vertical space than the final compact settings mockup. | implementor
