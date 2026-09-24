import AppKit
import Observation

enum ScreenshotTextCopyState: Equatable, Sendable {
    case recognizing, copying, copied, noText, unavailable, multipleFrames, tooLarge, failed, copyFailed, writeFailed, cancelled, clipboardChanged

    var offersRetry: Bool {
        self == .failed || self == .copyFailed || self == .writeFailed || self == .clipboardChanged || self == .cancelled
    }

    static func actionTitle(for state: Self?) -> String {
        state?.offersRetry == true ? "Try Copying Text Again" : "Copy Text"
    }

    static func accessibilityActionTitle(for state: Self?, filename: String) -> String {
        "\(actionTitle(for: state)) from \(filename)"
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
        case .writeFailed: "Copy failed; the clipboard may have been cleared. Try copying text again."
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
    private(set) var activeOperationID: UUID?
    private let recognizer: any ScreenshotTextRecognizing
    private let writer: any ScreenshotPasteboardWriting
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var feedbackToken = UUID()
    private var activePublishesRowFeedback = true
    private var activeStateChange: (@MainActor (ScreenshotTextCopyState) -> Void)?

    init(recognizer: any ScreenshotTextRecognizing = LocalScreenshotTextRecognizer(),
         writer: any ScreenshotPasteboardWriting) {
        self.recognizer = recognizer
        self.writer = writer
    }

    @discardableResult
    func start(_ record: RecentHistoryRecord,
               operationID: UUID = UUID(),
               publishRowFeedback: Bool = true,
               onStateChange: (@MainActor (ScreenshotTextCopyState) -> Void)? = nil,
               isCurrent: @escaping @MainActor (RecentHistoryRecord) async -> Bool) -> Bool {
        guard activeID == nil, record.saveOutcome == .success,
              let reference = record.savedReference, reference.role == .savedCopy else { return false }
        generation &+= 1
        let token = generation
        let boardCount = writer.changeCount
        activeID = record.captureID
        activeOperationID = operationID
        activeStateChange = onStateChange
        activePublishesRowFeedback = publishRowFeedback
        if publishRowFeedback {
            feedbackTask?.cancel(); feedbackTask = nil; feedbackToken = UUID()
            states = states.filter { $0.value != .copied }
            if states.count >= RecentHistoryStore.maxRecords { states.removeAll() }
            states[record.captureID] = .recognizing
        }
        task = Task { [self] in
            defer { activeID = nil; activeOperationID = nil; task = nil; activeStateChange = nil; activePublishesRowFeedback = true }
            do {
                let text = try await recognizer.recognize(reference)
                guard generation == token, !Task.isCancelled else { return }
                try ScreenshotTextLimits.validateOutput(text)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    if await canPublishFeedback(record, token: token, publishRowFeedback: publishRowFeedback, onStateChange: onStateChange, isCurrent: isCurrent) {
                        if publishRowFeedback { states[record.captureID] = .noText }
                        onStateChange?(.noText)
                    }
                    return
                }
                try await recognizer.revalidate(reference)
                guard await canPublishFeedback(record, token: token, publishRowFeedback: publishRowFeedback, onStateChange: onStateChange, isCurrent: isCurrent) else { return }
                guard writer.changeCount == boardCount else { throw ScreenshotTextFailure.clipboardChanged }
                if publishRowFeedback { states[record.captureID] = .copying }
                onStateChange?(.copying)
                let item = writer.makeItem()
                guard writer.setString(text, forType: .string, on: item) else { throw ScreenshotTextFailure.representationFailed }
                // No suspension from the final order check through the pasteboard write.
                guard generation == token, !Task.isCancelled, writer.changeCount == boardCount else {
                    throw ScreenshotTextFailure.clipboardChanged
                }
                writer.prepareForNewContents()
                guard writer.write(item) else { throw ScreenshotTextFailure.writeFailed }
                if publishRowFeedback {
                    states[record.captureID] = .copied
                    feedbackTask?.cancel()
                    feedbackToken = UUID()
                    let expiryToken = feedbackToken
                    feedbackTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(1.2))
                        guard !Task.isCancelled, let self, self.feedbackToken == expiryToken,
                              self.states[record.captureID] == .copied else { return }
                        self.states.removeValue(forKey: record.captureID)
                    }
                }
                onStateChange?(.copied)
            } catch {
                guard await canPublishFeedback(record, token: token, publishRowFeedback: publishRowFeedback, onStateChange: onStateChange, isCurrent: isCurrent) else { return }
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
                if publishRowFeedback { states[record.captureID] = state }
                onStateChange?(state)
            }
        }
        onStateChange?(.recognizing)
        return true
    }

    /// A revision lookup may suspend. Recheck cancellation afterward before touching
    /// row state so a removed row or cancelled job cannot be resurrected by its result.
    private func canPublishFeedback(_ record: RecentHistoryRecord, token: UInt64,
        publishRowFeedback: Bool,
        onStateChange: (@MainActor (ScreenshotTextCopyState) -> Void)?,
        isCurrent: @MainActor (RecentHistoryRecord) async -> Bool) async -> Bool {
        guard generation == token, !Task.isCancelled else { return false }
        let current = await isCurrent(record)
        guard generation == token, !Task.isCancelled else { return false }
        if !current {
            if publishRowFeedback { states.removeValue(forKey: record.captureID) }
            onStateChange?(.cancelled)
        }
        return current
    }

    func cancel() {
        generation &+= 1
        if activeID == nil || activePublishesRowFeedback {
            feedbackTask?.cancel(); feedbackTask = nil; feedbackToken = UUID()
            states = states.filter { $0.value != .copied }
        }
        task?.cancel()
        if let activeID {
            if activePublishesRowFeedback { states[activeID] = .cancelled }
            activeStateChange?(.cancelled)
        }
    }

    /// Surface-local cancellation cannot cancel a later operation, even for the same capture.
    func cancel(operationID: UUID) {
        guard activeOperationID == operationID else { return }
        cancel()
    }

    func waitForIdle(operationID: UUID) async {
        guard activeOperationID == operationID else { return }
        let admittedTask = task
        await admittedTask?.value
    }

    func retain(_ ids: Set<UUID>) {
        if let activeID, !ids.contains(activeID) { cancel() }
        retainFeedback(ids)
    }

    /// Refreshing Recents does not own cancellation of a thumbnail's OCR operation.
    func retainFeedback(_ ids: Set<UUID>) {
        states = states.filter { ids.contains($0.key) }
    }

    func clearUnavailable(_ id: UUID) {
        if states[id] == .unavailable { states.removeValue(forKey: id) }
    }

    /// Also used by deterministic tests; does not grant a second admission slot.
    func waitForIdle() async { await task?.value }
}
