# ShotDrop roadmap

## Local product implementation
- [x] Menu bar app, library, settings, About, app icon, launch-at-login control
- [x] Screenshot detection, bounded readiness and duplicate suppression
- [x] Active ordered auto-copy/save pipeline after setup
- [x] Image/file/both copying, including JPEG/HEIC-to-PNG clipboard conversion
- [x] Source-preserving saves, names, collision handling and date folders
- [x] Destination checks, failure status and Retry Saving
- [x] Finishable onboarding with folder-access explanations
- [x] Floating thumbnail and drag-out actions
- [x] Recent 20 screenshots, copy/open/reveal, clear history and confirmed Trash
- [x] On-device OCR
- [x] Annotation tools, undo/redo, crop, Save Copy and Save & Copy
- [x] Pinned windows, manager and reachable image viewport
- [x] Capture menu and optional screen/selection/window hotkeys
- [x] Pause/resume, display sleep/wake and graceful quit
- [x] Distribution/notarization instructions

## Verification and distribution
- [x] Native setup advancement, ready library, generated-fixture processing,
      OCR feedback, annotation export and pin management observed
- [x] Automated core, regression and integration tests (see VALIDATION.md)
- [ ] Native system-capture shortcuts and optional capture-permission flow
- [ ] Sustained performance/memory measurements across large native captures
- [ ] macOS 14 runtime, physical multi-display/Spaces and VoiceOver acceptance
- [ ] Fresh-account TCC denial/recovery and actual launch-at-login reboot test
- [ ] Developer ID signing, notarization and public-release acceptance

Implementation checkboxes describe shipped local code, not proof of every hardware
or operating-system scenario. Remaining observations are explicit in VALIDATION.md.
