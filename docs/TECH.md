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
`NSPasteboard.general`: write both `NSImage` (PNG/TIFF) and the file URL, configurable. Avoid huge memory spikes on 6K displays by writing PNG data lazily via `NSPasteboardItem` data providers.

## Rename / move
`ScreenshotOrganizer` stages a source-preserving copy in the destination directory. Source and destination descriptors remain pinned during copying; SHA256 streams in bounded chunks, metadata xattrs are verified, and `renameatx_np(RENAME_EXCL)` publishes without overwriting existing names. Collisions reuse the staged copy with numbered filenames. Originals are not deleted; optional cleanup belongs to v1.1. Directory and source identity checks reject path substitution. Post-publication failures retain the published copy and expose its recovery URL.

Naming supports `{app}`, `{date}`, `{time}` and optional Gregorian `YYYY/MM` folders using the supplied time zone. Unknown/malformed tokens fail before I/O; filename components are sanitized and byte-limited. A pre-publication hook reserves the stage identity in `ScreenshotDetector.ignoreOutput` to prevent feedback when source and destination overlap. Neither service is activated from the app yet.

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
