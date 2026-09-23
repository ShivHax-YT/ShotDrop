# ShotDrop — Technical plan

## Stack
Swift 6, SwiftUI + AppKit, menu bar app (`LSUIElement = YES`), XcodeGen project, macOS 14.0+. Distribution: Developer ID, not sandboxed for v1 (simpler file access). Keep the architecture sandbox-ready.

## How screenshots are detected
- Primary: file-level FSEvents with FileEvents, NoDefer, WatchRoot, and 50 ms configured notification latency. Actor-owned detection handles only direct, visible PNG/JPG/JPEG/HEIC children of the source folder. Event coalescing/drop flags trigger reconciliation; a moved/unavailable root stops detection with an actionable status.
- Readiness: at most ten observations across approximately five seconds, requiring two consecutive stable identity/size/mtime observations, a true screenshot-marker xattr, and a complete ImageIO image. File-descriptor reads reject symlinks and check identity before/after reading. Four candidates can be checked concurrently; no idle polling. Later filesystem events can reawaken exhausted candidates.
- Optional reconciliation: `NSMetadataQuery` with predicate `kMDItemIsScreenCapture == 1`. Initial gathering is suppressed; later URLs pass through the same validation and identity deduplication as filesystem hints. Missing Spotlight results never gate filesystem detection.
- Startup history and emitted files are deduplicated for the detector session by device/inode/birth time. Observation starts before the baseline scan, and creations during startup are distinguished by birth time. A future move/copy coordinator must prevent its own newly created output identities from entering the source pipeline.
- System screenshot location: read `defaults read com.apple.screencapture location` (default ~/Desktop). Offer (optional) to change it to a hidden inbox folder so the Desktop stays clean. That writes another app's defaults domain, so do it only with explicit user consent.
- Ignore the temporary file macOS writes while the floating system thumbnail is shown (it finalizes after the thumbnail disappears). Research: whether to recommend users turn off "Show Floating Thumbnail" in the Cmd+Shift+5 options for instant files.
- `ScreenshotDetector` is explicitly started/stopped and is currently exercised by synthetic tests only; app startup does not access Desktop. Wire it into the permission and complete copy/save flow before enabling user capture processing. The future app coordinator must stop/resume detection around display sleep.

## Clipboard
`ScreenshotClipboardPreparer` reads bounded encoded image data through a pinned, non-symlink descriptor off MainActor. The image path currently accepts verified complete PNG only (64 MiB encoded-data limit); JPEG/HEIC are never labeled PNG. Non-PNG screenshots may still use File mode. No full-size NSImage/TIFF conversion or lazy provider is used. Prepared immutable PNG bytes remain independent of later source moves or changes.

`ScreenshotClipboardPublisher` receives an explicitly selected pasteboard and writes one fresh `NSPasteboardItem`: Image has `public.png`, File has `public.file-url`, and Both has both types on that same item. File/Both require an explicit surviving saved destination or original, with identity and metadata revalidation off MainActor immediately before publication. A file URL references its current path; it cannot follow later moves or guarantee future access. There is no atomic transaction spanning filesystem mutations by other processes and pasteboard publication.

Item representation setup occurs before ownership changes and every setup/write result is checked. MainActor prepares current-host-only ownership and writes synchronously without an intervening await. Setup/preflight failures preserve prior ownership; a write failure after preparation may leave the clipboard cleared. The service does not read or back up the user's clipboard and promises no rollback. Only successful AppKit writes return a copied receipt. The `beforeOwnership` hook lets the future integration coordinator reject superseded work after asynchronous file revalidation and before any ownership change; ordering policy belongs to the pipeline integration coordinator.

Tests use uniquely named private pasteboards and injected writers, never the general clipboard. App startup still does not activate copying. Real Finder, rich-text, browser/app, after-quit, folder-permission, and cross-device behavior require separate QA. Both offers representations and cannot control which type a consumer chooses. Existing native labeled menu preference remains Image / File / Image and file, with system keyboard and accessibility behavior.

API availability is checked against the installed SDK with deployment target macOS 14: [writeObjects](https://developer.apple.com/documentation/appkit/nspasteboard/writeobjects(_:)) and item data setup date from macOS 10.6; [currentHostOnly](https://developer.apple.com/documentation/appkit/nspasteboard/contentsoptions/currenthostonly) ownership options date from macOS 10.12.

## Rename / move
`ScreenshotOrganizer` stages a source-preserving copy in a private 0700 directory on the destination volume. Source and stage descriptors remain pinned; SHA256 streams in bounded chunks and extended attributes are verified. `fclonefileat` publishes exclusively from the pinned stage descriptor, so replacing its pathname cannot redirect publication. Collisions reuse the stage with numbered filenames. Clone support is required on the destination filesystem; unsupported, cross-device, full-disk, and permission failures retain the source and report failure, with no pathname-rename fallback. A source on another volume is copied into the destination-local stage first, but separate physical-volume acceptance is still pending. Originals are not deleted; optional source cleanup belongs to v1.1. Post-publication failures keep outputs and return a verified recovery path when one can be found.

Stage cleanup uses descriptor-bound truncation and never unlinks or removes a pathname. Empty private staging directories and stage files remain after each transaction; if truncation fails or a substituted output aliases the stage inode, the owned stage retains bytes. Output aliases to the stage are rejected before any success receipt. Darwin has no inode-conditional unlink, so retaining these artifacts avoids deleting a replacement inserted after an identity check. This storage/housekeeping limitation is explicit until a safe lifecycle is designed.

Naming supports `{app}`, `{date}`, `{time}` and optional Gregorian `YYYY/MM` folders using the supplied time zone. Unknown/malformed tokens fail before I/O; filename components are sanitized and byte-limited. A pre-publication hook registers a fresh UUID output token with `ScreenshotDetector.ignoreOutput(token:)`. The token is stored in `com.macfleet.shotdrop.output-token`, copied by clone, and read through the detector's pinned descriptor; this prevents feedback despite the clone receiving a new inode. All source metadata is preserved except an existing value of this app-private provenance attribute, which is replaced on the copy. The source itself is unchanged. Neither service is activated from the app yet.

Frontmost app: `NSWorkspace.shared.frontmostApplication` sampled at detection time is only a best-effort naming hint. History remains future work (small JSON store or SQLite).

## Permissions
TCC "Desktop folder" access prompt when reading ~/Desktop. No Screen Recording permission is needed unless we add our own capture (ScreenCaptureKit) in v1.1.

## Risks
- The screenshot xattr is an identification heuristic rather than a documented capture-event contract. Missing/changed markers fail closed; originals remain untouched.
- Candidate-to-ready timings include readiness queue time; readiness sampling time is also returned independently. Native shortcut-to-file and file-to-clipboard timing still need real-capture acceptance measurements.
- Floating system thumbnail delays file creation by ~5 s.
- Ad-hoc signed debug builds lose TCC grants on each rebuild. Sign with an Apple Development identity (free personal team) so permissions stick.

## References to research
Apple docs: NSMetadataQuery, NSPasteboard, ScreenCaptureKit, Vision (VNRecognizeTextRequest).
