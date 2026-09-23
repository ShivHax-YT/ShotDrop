# ShotDrop — Technical plan

## Stack
Swift 6, SwiftUI + AppKit, menu bar app (`LSUIElement = YES`), XcodeGen project, macOS 14.0+. Distribution: Developer ID, not sandboxed for v1 (simpler file access). Keep the architecture sandbox-ready.

## How screenshots are detected
- Primary: `NSMetadataQuery` with predicate `kMDItemIsScreenCapture == 1`, scoped to the system screenshot location. Fires when Spotlight indexes the new file. Measure latency; research should compare with FSEvents.
- Fallback / faster: FSEvents (or `DispatchSource` file-system object) watching the screenshot folder, filtering new PNG/JPG/HEIC files and confirming via the `com.apple.metadata:kMDItemIsScreenCapture` xattr.
- System screenshot location: read `defaults read com.apple.screencapture location` (default ~/Desktop). Offer (optional) to change it to a hidden inbox folder so the Desktop stays clean. That writes another app's defaults domain, so do it only with explicit user consent.
- Ignore the temporary file macOS writes while the floating system thumbnail is shown (it finalizes after the thumbnail disappears). Research: whether to recommend users turn off "Show Floating Thumbnail" in the Cmd+Shift+5 options for instant files.

## Clipboard
`NSPasteboard.general`: write both `NSImage` (PNG/TIFF) and the file URL, configurable. Avoid huge memory spikes on 6K displays by writing PNG data lazily via `NSPasteboardItem` data providers.

## Rename / move
`FileManager.moveItem`, collision-safe naming, preserve the metadata xattrs. Frontmost app: `NSWorkspace.shared.frontmostApplication` sampled at detection time. Store history in a small SQLite (GRDB) or JSON store.

## Permissions
TCC "Desktop folder" access prompt when reading ~/Desktop. No Screen Recording permission is needed unless we add our own capture (ScreenCaptureKit) in v1.1.

## Risks
- Detection latency (Spotlight). Mitigate with FSEvents.
- Floating system thumbnail delays file creation by ~5 s.
- Ad-hoc signed debug builds lose TCC grants on each rebuild. Sign with an Apple Development identity (free personal team) so permissions stick.

## References to research
Apple docs: NSMetadataQuery, NSPasteboard, ScreenCaptureKit, Vision (VNRecognizeTextRequest).
