# ShotDrop — Decisions

Judgment calls made without asking. `YYYY-MM-DD | decision | why | who`

2026-09-22 | M0 uses native SwiftUI MenuBarExtra and Settings scenes, Observation-backed preferences, and SMAppService.mainApp. No third-party dependencies. | Keeps the macOS 14 scaffold small and idle without timers. | implementor
2026-09-22 | Launch at login defaults off and changes only from an explicit settings action; the UI reflects Service Management status and approval/error states. | Registration is user intent, not a startup side effect. | implementor
2026-09-22 | M0 stores future capture preferences but clearly labels screenshot processing as unavailable until M1; no file watchers, clipboard writes, or folder creation at startup. | A usable shell must not imply a working screenshot pipeline or trigger premature privacy prompts. | implementor
2026-09-22 | Until a development team is configured locally, debug builds use ad-hoc signing. Actual login-at-login and TCC persistence remain separate system acceptance checks. | No signing team was provided; the scaffold can build and launch without credentials. | implementor
2026-09-22 | Keep M0's native menu and grouped Settings form; defer the design report's recent-item panel to M2. | M0 is a shell, and the inactive-processing explanation requires more vertical space than the final compact settings mockup. | implementor
2026-09-22 | #20 makes FSEvents primary, with bounded readiness and optional Spotlight reconciliation. | The research spike observed create-before-content/xattr races and no prompt synthetic Spotlight update. File hints alone cannot prove readiness. | implementor
2026-09-22 | #20 validates via a pinned non-symlink descriptor, bounded binary-plist marker, complete image decode, and consecutive stable observations. | Fail closed on ordinary, malformed, or still-changing images; detection never modifies originals. | implementor
2026-09-22 | Keep the detector explicitly startable as a service until permission and copy/save coordination are implemented. | Starting a Desktop watcher from the existing shell would trigger unexplained folder access before the planned onboarding; synthetic tests exercise the real watcher without user-file access. | implementor
2026-09-22 | Root relocation stops the detector with a retryable status; restart re-resolves system location. | Do not silently follow a directory inode after the user's configured path changes. No automatic defaults writes. | implementor
