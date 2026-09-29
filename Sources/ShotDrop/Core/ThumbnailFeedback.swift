import Observation

/// Snapshot pixels remain usable even after the saved file becomes unavailable.
@MainActor @Observable
final class ThumbnailFeedback {
    var status: String?
    var isKeyWindow = false
    private(set) var fileActionsAvailable = true

    func beginPresentation(isKeyWindow: Bool) {
        status = nil
        fileActionsAvailable = true
        self.isKeyWindow = isKeyWindow
    }

    func apply(_ result: PinScreenshotActionResult, action: PinScreenshotAction) {
        status = result.status
        // Copying cached pixels doesn't validate or restore the saved file.
        if action != .copyImage { fileActionsAvailable = result.fileActionsAvailable }
    }
}
