# ShotDrop — Roadmap

The implementor ticks boxes as items land. Each milestone ends with a QA pass.

## M0 — Scaffold
- [x] XcodeGen project.yml, menu bar app shell (LSUIElement), app icon placeholder, launch-at-login (SMAppService)
- [x] Settings window skeleton, unit test target, `make`-style build script in README

M0 validation: Debug build and 9 unit tests pass; app process launched. GUI acceptance is pending QA because the computer-use surface timed out. Actual login-at-login behavior and stable-signing TCC persistence are not yet verified.
## M1 — Core pipeline
- [x] Detect new screenshots (FSEvents primary + optional NSMetadataQuery reconciliation), log latency
- [ ] Auto-copy to clipboard (image + file URL options)
- [x] Save verified copies to chosen folder with rename template and collision handling (originals retained)
- [x] Source-preserving file operations + failure tests

Detection validation: 51 tests pass, including a real filesystem watcher with synthetic PNG/xattr fixtures, late metadata, deduplication, and cancellation races. The detector service is not started by the app yet. Native system-capture timing and source-folder permission acceptance remain pending.

Organization validation: 89 total tests pass, including naming, metadata/byte verification, collisions, cancellation, tampering, post-publication recovery, and source/destination overlap. Injected EXDEV, ENOSPC, and EACCES preserve originals. Separate physical-volume behavior and real folder-permission acceptance remain unverified; automatic app processing and destination-failure UI are still pending.
## M2 — UX
- [ ] Floating thumbnail with drag-out, click-to-open, swipe-to-dismiss
- [ ] Menu bar recent list (20) with copy/reveal/delete
- [ ] Onboarding + permission explainer
## M3 — Power features
- [ ] OCR copy text (Vision)
- [ ] Quick annotate window (arrow, rect, blur, text, crop)
- [ ] Pin screenshot as floating window
## M4 — Ship
- [ ] Performance pass (idle CPU ~0%, memory)
- [ ] App icon, About window, Sparkle updates (optional), notarization notes
- [ ] QA release checklist green
