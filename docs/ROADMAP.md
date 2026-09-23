# ShotDrop — Roadmap

The implementor ticks boxes as items land. Each milestone ends with a QA pass.

## M0 — Scaffold
- [x] XcodeGen project.yml, menu bar app shell (LSUIElement), app icon placeholder, launch-at-login (SMAppService)
- [x] Settings window skeleton, unit test target, `make`-style build script in README

M0 validation: Debug build and 9 unit tests pass; app process launched. GUI acceptance is pending QA because the computer-use surface timed out. Actual login-at-login behavior and stable-signing TCC persistence are not yet verified.
## M1 — Core pipeline
- [x] Detect new screenshots (FSEvents primary + optional NSMetadataQuery reconciliation), log latency
- [x] Clipboard service with one-item Image / File / Both publication and private-board tests
- [ ] Activate ordered auto-copy pipeline after source access and bounded staging acceptance
- [x] Save verified copies to chosen folder with rename template and collision handling (originals retained)
- [x] Source-preserving file operations + failure tests
- [x] Destination separation, truthful save outcomes, and retry/recovery actions

Detection validation: 51 tests pass, including a real filesystem watcher with synthetic PNG/xattr fixtures, late metadata, deduplication, and cancellation races. The detector service is not started by the app yet. Native system-capture timing and source-folder permission acceptance remain pending.

Organization validation (#107 repair): production Debug build and 98 unhosted Core tests pass. Both stage pathname races fail deterministically on the #21 baseline and pass with descriptor-bound clone publication and cleanup. Coverage includes hardlink output substitution, metadata/byte verification, exclusive collisions, cancellation, post-publication recovery, UUID output suppression, and actual clone-call injection of ENOTSUP, EXDEV, ENOSPC, and EACCES. Review accepted the race repairs and QA passed 31 fresh focused tests against the frozen 38d35de candidate. The earlier retained per-capture staging design is superseded by #228 below. Separate physical-volume behavior and real folder-permission acceptance remain pending; automatic app processing and destination-failure UI are still pending.
Clipboard validation (#121): all 117 unhosted Core tests pass, including 19 new preparation and private-board tests. Image/File/Both have exactly the intended types on one item; readback, validation, cancellation, setup/write failure, and source/path changes are covered. Image mode currently accepts PNG only, bounded to 64 MiB encoded data. Real consumer, after-quit, macOS 14 runtime, GUI/TCC, and automatic pipeline acceptance remain pending.
Save recovery validation (#122): all 151 unhosted tests pass (34 new tests) and the recovery component compiles. Fixtures cover destination identity/ancestry, aliases, source-root mismatch, missing destinations, permission failures, clone errors, verification failure, collision races/exhaustion, direct retry, cancellation, and changed/unavailable originals. Native recovery presentation is ready for pipeline integration; actual keyboard/VoiceOver, GUI/TCC, and physical cross-volume behavior remain unverified.

Bounded staging validation (#228): all 222 signed unhosted tests pass, including 10,000 successful synthetic transactions with two stable slot identities and no pool-entry growth. Fixed pools enforce one active transaction, four registered roots, two slots per root, bounded payload/metadata, persistent volume UUID identity, explicit destination review, and durable retirement on uncertainty. Disposable fixtures cover collision retry, cancellation/contention, interrupted states, reset/journal failures, source preservation, inherited destination ACLs, and exact provenance baseline reuse. The 257-byte workload completed in 97.53 seconds; save-operation mean/p95 were 9.30/17.54 ms, excluding fixture assertions and output removal. This is neither native screenshot latency nor a physical disk quota measurement. Admission is initially limited to reviewed ordinary local directories on writable internal APFS; missing/replaced selected roots pause until explicit re-review. Production enrollment remains unavailable and processing stays inactive. Independent exact-candidate QA/Review, setup, real TCC, physical remount/disconnect, macOS 14 runtime, and zero-configuration acceptance remain open.

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
