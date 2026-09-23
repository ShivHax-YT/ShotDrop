import AppKit
import Observation

enum ScreenshotTextCopyState: Equatable, Sendable {
    case recognizing, copying, copied, noText, unavailable, multipleFrames, tooLarge, failed, copyFailed, writeFailed, cancelled, clipboardChanged

    var offersRetry: Bool {
        self == .failed || self == .copyFailed || self == .writeFailed || self == .clipboardChanged || self == .cancelled
    }

    var message: String {
        switch self {
        case .recognizing: "Recognizing text…"
        case .copying: "Copying text…"
        case .copied: "Text copied"
        case .noText: "No text found in screenshot"
        case .unavailable: "File unavailable"
        case .multipleFrames: "Copy Text requires a single-frame saved image"
        case .tooLarge: "Screenshot or text too large · Try a smaller saved image"
        case .failed: "Couldn’t recognize text · Try Copying Text Again"
        case .copyFailed: "Couldn’t copy text · Try Copying Text Again"
        case .writeFailed: "Couldn’t copy text. Your clipboard may have changed."
        case .cancelled: "Text recognition cancelled"
        case .clipboardChanged: "Clipboard changed · Try Copying Text Again"
        }
    }
}

/// One admitted operation, no pending queue. Cancellation fences publication but
/// retains the admission slot until the worker exits, even if Vision ignores it.
@MainActor
@Observable
final class ScreenshotTextCopyController {
    private(set) var states: [UUID: ScreenshotTextCopyState] = [:]
    private(set) var activeID: UUID?
    private let recognizer: any ScreenshotTextRecognizing
    private let writer: any ScreenshotPasteboardWriting
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?

    init(recognizer: any ScreenshotTextRecognizing = LocalScreenshotTextRecognizer(),
         writer: any ScreenshotPasteboardWriting) {
        self.recognizer = recognizer
        self.writer = writer
    }

    @discardableResult
    func start(_ record: RecentHistoryRecord,
               isCurrent: @escaping @MainActor (RecentHistoryRecord) async -> Bool) -> Bool {
        guard activeID == nil, record.saveOutcome == .success,
              let reference = record.savedReference, reference.role == .savedCopy else { return false }
        generation &+= 1
        let token = generation
        let boardCount = writer.changeCount
        activeID = record.captureID
        states = states.filter { $0.value != .copied }
        if states.count >= RecentHistoryStore.maxRecords { states.removeAll() }
        states[record.captureID] = .recognizing
        task = Task { [self] in
            defer { activeID = nil; task = nil }
            do {
                let text = try await recognizer.recognize(reference)
                guard generation == token, !Task.isCancelled else { return }
                try ScreenshotTextLimits.validateOutput(text)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    states[record.captureID] = .noText
                    return
                }
                try await recognizer.revalidate(reference)
                guard await isCurrent(record), generation == token, !Task.isCancelled else {
                    if generation == token { states[record.captureID] = .cancelled }
                    return
                }
                guard writer.changeCount == boardCount else { throw ScreenshotTextFailure.clipboardChanged }
                states[record.captureID] = .copying
                let item = writer.makeItem()
                guard writer.setString(text, forType: .string, on: item) else { throw ScreenshotTextFailure.representationFailed }
                // No suspension from the final order check through the pasteboard write.
                guard generation == token, !Task.isCancelled, writer.changeCount == boardCount else {
                    throw ScreenshotTextFailure.clipboardChanged
                }
                writer.prepareForNewContents()
                guard writer.write(item) else { throw ScreenshotTextFailure.writeFailed }
                states[record.captureID] = .copied
                feedbackTask?.cancel()
                feedbackTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled, let self, self.generation == token,
                          self.states[record.captureID] == .copied else { return }
                    self.states.removeValue(forKey: record.captureID)
                }
            } catch {
                guard generation == token else { return }
                let state: ScreenshotTextCopyState
                switch error {
                case is CancellationError: state = .cancelled
                case ScreenshotTextFailure.fileUnavailable: state = .unavailable
                case ScreenshotTextFailure.multipleFrames: state = .multipleFrames
                case ScreenshotTextFailure.inputTooLarge, ScreenshotTextFailure.outputTooLarge: state = .tooLarge
                case ScreenshotTextFailure.clipboardChanged: state = .clipboardChanged
                case ScreenshotTextFailure.representationFailed: state = .copyFailed
                case ScreenshotTextFailure.writeFailed: state = .writeFailed
                default: state = .failed
                }
                states[record.captureID] = state
            }
        }
        return true
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        if let activeID { states[activeID] = .cancelled }
    }

    func retain(_ ids: Set<UUID>) {
        if let activeID, !ids.contains(activeID) { cancel() }
        states = states.filter { ids.contains($0.key) }
    }

    func clearUnavailable(_ id: UUID) {
        if states[id] == .unavailable { states.removeValue(forKey: id) }
    }

    /// Also used by deterministic tests; does not grant a second admission slot.
    func waitForIdle() async { await task?.value }
}
