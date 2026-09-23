# ShotDrop — Roadmap

The implementor ticks boxes as items land. Each milestone ends with a QA pass.

## M0 — Scaffold
- [x] XcodeGen project.yml, menu bar app shell (LSUIElement), app icon placeholder, launch-at-login (SMAppService)
- [x] Settings window skeleton, unit test target, `make`-style build script in README

M0 validation: Debug build and 9 unit tests pass; app process launched. GUI acceptance is pending QA because the computer-use surface timed out. Actual login-at-login behavior and stable-signing TCC persistence are not yet verified.
## M1 — Core pipeline
- [ ] Detect new screenshots (NSMetadataQuery + FSEvents fallback), log latency
- [ ] Auto-copy to clipboard (image + file URL options)
- [ ] Move to chosen folder with rename template and collision handling
- [ ] Never-lose-a-file guarantees + tests
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
