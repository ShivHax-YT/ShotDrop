# ShotDrop — Roadmap

The implementor ticks boxes as items land. Each milestone ends with a QA pass.

## M0 — Scaffold
- [ ] XcodeGen project.yml, menu bar app shell (LSUIElement), app icon placeholder, launch-at-login (SMAppService)
- [ ] Settings window skeleton, unit test target, `make`-style build script in README
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
