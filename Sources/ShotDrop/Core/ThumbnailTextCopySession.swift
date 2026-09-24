import Foundation
import Observation

/// Adapts the one shared OCR admission to an immutable, transient thumbnail identity.
/// No decoder, clipboard writer, timer, or second OCR admission lives here.
@MainActor @Observable
final class ThumbnailTextCopySession {
    private let controller: ScreenshotTextCopyController
    private let history: RecentHistoryStore
    private let manualCopyIntent: () -> Void
    private(set) var identity: PinScreenshotIdentity?
    private(set) var state: ScreenshotTextCopyState?
    private(set) var isRunning = false
    private var operation: UUID?
    private var drain: Task<Void, Never>?
    @ObservationIgnored var onChange: (() -> Void)?

    init(controller: ScreenshotTextCopyController, history: RecentHistoryStore, manualCopyIntent: @escaping () -> Void) {
        self.controller = controller
        self.history = history
        self.manualCopyIntent = manualCopyIntent
    }
    var actionTitle: String { ScreenshotTextCopyState.actionTitle(for: state) }
    var canStart: Bool { identity?.reference.role == .savedCopy && !isRunning && controller.activeID == nil }
    func bind(_ identity: PinScreenshotIdentity?) {
        guard self.identity != identity else { return }
        cancel()
        self.identity = identity
        state = nil
        onChange?()
    }
    @discardableResult
    func start() -> Bool {
        guard canStart, let identity, identity.reference.role == .savedCopy else { return false }
        let token = UUID()
        let record = RecentHistoryRecord(captureID: identity.captureID, pipelineSequence: 0,
            detectionDate: Date(), displayName: URL(fileURLWithPath: identity.reference.lastKnownPath).lastPathComponent,
            sourceReference: nil, savedReference: identity.reference, copyOutcome: .pending,
            saveOutcome: .success, revision: identity.revision)
        operation = token
        isRunning = true
        let accepted = controller.start(record, operationID: token, publishRowFeedback: false, onStateChange: { [weak self] state in
            guard let self, self.operation == token, self.identity == identity else { return }
            self.state = state
            self.onChange?()
        }, isCurrent: { [weak self] candidate in
            guard let self, self.operation == token, self.identity == identity,
                  candidate.captureID == identity.captureID, candidate.revision == identity.revision,
                  candidate.savedReference == identity.reference,
                  let snapshot = try? await self.history.snapshot(),
                  let current = snapshot.records.first(where: { $0.captureID == identity.captureID }) else { return false }
            // History lookup suspends. Dismissal/replacement during that read must still fence publication.
            return self.operation == token && self.identity == identity
                && current.revision == identity.revision && current.savedReference == identity.reference
                && current.saveOutcome == .success
        })
        guard accepted else { operation = nil; isRunning = false; return false }
        manualCopyIntent() // Integration must not cancel the OCR operation just admitted above.
        onChange?()
        drain = Task { [weak self, controller] in
            await controller.waitForIdle(operationID: token)
            guard let self else { return }
            self.isRunning = false
            self.operation = nil
            self.drain = nil
            self.onChange?()
        }
        return true
    }
    func cancel() {
        guard let operation, isRunning else { return }
        controller.cancel(operationID: operation)
        self.operation = nil // Late decoder/state callbacks cannot affect the next visible identity.
        if identity != nil { state = .cancelled }
        onChange?()
        // Keep isRunning until the shared worker actually returns, even if cancellation is ignored.
    }
    func waitForIdle() async { await drain?.value }
}
