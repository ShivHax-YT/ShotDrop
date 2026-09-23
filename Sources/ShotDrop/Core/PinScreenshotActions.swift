import AppKit

enum PinScreenshotAction { case copyImage, copyFile, open, reveal }
struct PinScreenshotActionResult {
    let status: String
    let fileActionsAvailable: Bool
}

/// Explicit user actions only. Snapshot pixels are independent from live file actions.
@MainActor
final class PinScreenshotActions {
    typealias Intent = @MainActor () throws -> Void
    private let publisher: ScreenshotClipboardPublisher
    private let beginClipboardIntent: () -> Intent
    private let open: (URL) -> Bool
    private let reveal: (URL) -> Bool
    private let renderer = AnnotationRenderer()
    private var busy = false

    init(writer: any ScreenshotPasteboardWriting,
         beginClipboardIntent: @escaping () -> Intent,
         open: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         reveal: @escaping (URL) -> Bool = { NSWorkspace.shared.selectFile($0.path, inFileViewerRootedAtPath: "") }) {
        publisher = ScreenshotClipboardPublisher(writer: writer)
        self.beginClipboardIntent = beginClipboardIntent
        self.open = open; self.reveal = reveal
    }

    func perform(_ snapshot: PinScreenshotSnapshot, action: PinScreenshotAction) async -> PinScreenshotActionResult {
        guard !busy else { return .init(status: "Another pin action is finishing. Try again shortly.", fileActionsAvailable: true) }
        busy = true
        defer { busy = false }
        do {
            try Task.checkCancellation()
            if action == .copyImage {
                let intent = beginClipboardIntent()
                let pixels = snapshot.image
                let source = AnnotationSource(reference: snapshot.identity.reference,
                    width: pixels.width, height: pixels.height, rgba: pixels.rgba)
                let state = try AnnotationDocument(width: pixels.width, height: pixels.height).state
                let png = try await renderer.png(source: source, state: state)
                let prepared = try await PreparedScreenshotClipboard.snapshotPNG(png)
                _ = try await publisher.publish(prepared) { try Task.checkCancellation(); try intent() }
                return .init(status: snapshot.isReduced ? "Copied preview image at its displayed resolution." : "Copied pinned image.", fileActionsAvailable: true)
            }
            let intent = action == .copyFile ? beginClipboardIntent() : nil
            let resolution = await Self.resolve(snapshot.identity.reference)
            try Task.checkCancellation()
            guard case .available(let file) = resolution, file.role == .savedCopy else {
                return .init(status: "The saved file is unavailable or changed. This pin still shows the earlier image. Open Recents to recover it.", fileActionsAvailable: false)
            }
            switch action {
            case .copyFile:
                let request = ScreenshotClipboardRequest(sourceURL: file.url, mode: .file,
                    expectedIdentity: file.liveIdentity, survivingFileURL: file.url, survivingFileIdentity: file.liveIdentity)
                let prepared = try await ScreenshotClipboardPreparer().prepare(request)
                _ = try await publisher.publish(prepared) { try Task.checkCancellation(); try intent?() }
                return .init(status: "Copied verified saved file reference.", fileActionsAvailable: true)
            case .open:
                return .init(status: open(file.url) ? "Asked the default app to open the verified saved copy." : "Could not open the saved copy.", fileActionsAvailable: true)
            case .reveal:
                return .init(status: reveal(file.url) ? "Asked Finder to reveal the verified saved copy." : "Could not reveal the saved copy.", fileActionsAvailable: true)
            case .copyImage: preconditionFailure("Snapshot copy handled above")
            }
        } catch is CancellationError {
            return .init(status: "Pin action cancelled.", fileActionsAvailable: true)
        } catch {
            return .init(status: "Could not complete the pin action. \(error.localizedDescription)", fileActionsAvailable: true)
        }
    }

    @concurrent
    private static func resolve(_ reference: RecentFileReference) async -> RecentFileResolution {
        RecentFileResolver().resolve(reference)
    }
}
