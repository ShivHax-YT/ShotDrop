import Foundation
import Observation

/// Readiness is tied to the inspected folders, not merely to a successful access prompt.
struct ShotDropSetupReadinessBinding: Equatable, Sendable {
    let source: ShotDropSetupDirectoryIdentity
    let destination: ShotDropSetupDirectoryIdentity
}

struct ShotDropSetupReadiness: Sendable {
    let binding: ShotDropSetupReadinessBinding
    let destinationReady: Bool
    let pipelineReady: Bool
    let boundReviewApproved: Bool

    func permitsTest(for expected: ShotDropSetupReadinessBinding) -> Bool {
        binding == expected && destinationReady && pipelineReady && boundReviewApproved
    }
}

protocol ShotDropSetupReadinessGating: Sendable {
    func evaluate(_ binding: ShotDropSetupReadinessBinding) async -> ShotDropSetupReadiness
}

/// Production deliberately has no issuer for the independently reviewed staging authorization.
struct ShotDropSetupUnavailableGate: ShotDropSetupReadinessGating {
    func evaluate(_ binding: ShotDropSetupReadinessBinding) async -> ShotDropSetupReadiness {
        ShotDropSetupReadiness(binding: binding, destinationReady: false,
                               pipelineReady: false, boundReviewApproved: false)
    }
}

@MainActor
@Observable
final class ShotDropSetupModel {
    enum Step: Int, CaseIterable { case welcome, destination, source, test }

    private(set) var step: Step = .welcome
    private(set) var destinationURL: URL?
    private(set) var sourceURL: URL?
    private(set) var isBusy = false
    private(set) var isPresented = true
    private(set) var isDeferred = false
    private(set) var sourceConfirmedByUser = false
    private(set) var destinationNeedsReview = false
    private(set) var statusMessage: String?
    private(set) var sourceIssue: ShotDropSetupAccessIssue?
    private(set) var destinationIssue: ShotDropSetupAccessIssue?
    private(set) var requiresSourceSelection = false
    private(set) var isSourceLocationUnknown = false

    @ObservationIgnored private let service: any ShotDropSetupAccessServing
    @ObservationIgnored private let gate: any ShotDropSetupReadinessGating
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var expectedSourceIdentity: ShotDropSetupDirectoryIdentity?
    @ObservationIgnored private var verifiedBinding: ShotDropSetupReadinessBinding?
    @ObservationIgnored private var readiness: ShotDropSetupReadiness?

    init(destinationURL: URL? = nil, sourceURL: URL? = nil,
         service: any ShotDropSetupAccessServing = LocalShotDropSetupAccessService(),
         gate: any ShotDropSetupReadinessGating = ShotDropSetupUnavailableGate()) {
        self.destinationURL = destinationURL
        self.sourceURL = sourceURL
        self.service = service
        self.gate = gate
    }

    var canGoBack: Bool { isPresented && step != .welcome }
    var canContinue: Bool {
        guard isPresented, !isBusy else { return false }
        switch step {
        case .welcome: return true
        case .destination: return destinationURL != nil
        case .source: return destinationURL != nil && sourceURL != nil && sourceConfirmedByUser && !requiresSourceSelection
        case .test: return canRunTest
        }
    }
    var primaryTitle: String {
        switch step {
        case .welcome: "Continue"
        case .destination: destinationIssue == nil ? "Use This Folder" : "Retry"
        case .source: sourceIssue == nil ? "Continue" : "Retry"
        case .test: "Done"
        }
    }
    var canRunTest: Bool {
        guard isPresented, step == .test, !isBusy, let verifiedBinding else { return false }
        return readiness?.permitsTest(for: verifiedBinding) == true
    }

    func selectDestination(_ url: URL) {
        invalidate()
        destinationURL = url
        destinationIssue = nil
        destinationNeedsReview = false
        statusMessage = nil
        if step == .test { step = .destination }
    }

    /// Selection is a draft only. It neither changes macOS preferences nor proves this is its source.
    func selectSource(_ url: URL) {
        invalidate()
        sourceURL = url
        sourceIssue = nil
        requiresSourceSelection = false
        isSourceLocationUnknown = false
        expectedSourceIdentity = nil
        sourceConfirmedByUser = false
        statusMessage = "Confirm that macOS currently saves screenshots in this folder."
        if step == .test { step = .source }
    }

    func confirmCurrentSource(_ confirmed: Bool) {
        invalidate()
        sourceConfirmedByUser = confirmed
        if step == .test { step = .source }
    }

    func continueSetup() async {
        guard canContinue else { return }
        if step == .welcome {
            step = .destination
            statusMessage = nil
            return
        }
        if step == .test {
            invalidate()
            isPresented = false
            isDeferred = false
            return
        }
        let selectedStep = step
        await perform { model, token in
            if selectedStep == .destination {
                await model.inspectDestination(token: token)
            } else if selectedStep == .source {
                await model.inspectReadiness(token: token)
            }
        }
    }

    /// A changed discovery result never silently replaces the user's selected source.
    func retrySourceDiscovery() async {
        guard isPresented, step == .source, !isBusy else { return }
        await perform { model, token in await model.discoverSource(token: token) }
    }

    func goBack() {
        guard canGoBack else { return }
        invalidate()
        sourceConfirmedByUser = false
        step = Step(rawValue: step.rawValue - 1) ?? .welcome
        statusMessage = nil
    }

    func notNow() {
        invalidate()
        sourceConfirmedByUser = false
        isPresented = false
        isDeferred = true
    }

    func reopen() {
        invalidate()
        step = .welcome
        isPresented = true
        isDeferred = false
        sourceConfirmedByUser = false
        destinationNeedsReview = false
        sourceIssue = nil
        destinationIssue = nil
        statusMessage = nil
    }

    private func perform(_ body: @escaping @MainActor (ShotDropSetupModel, UInt64) async -> Void) async {
        invalidate()
        let token = generation
        isBusy = true
        statusMessage = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await body(self, token)
            guard self.isCurrent(token) else { return }
            self.isBusy = false
            self.operation = nil
        }
        operation = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if generation == token, task.isCancelled { invalidate() }
    }

    private func inspectDestination(token: UInt64) async {
        guard let destinationURL else { return }
        let result = await service.checkDestination(destinationURL, source: nil, sourceIdentity: nil)
        guard isCurrent(token) else { return }
        switch result {
        case .needsReview:
            destinationIssue = nil
            destinationNeedsReview = true
            statusMessage = "Automatic copying and saving are not available in this build. Your save destination can be kept for later."
            step = .source
            await discoverSource(token: token)
        case .unavailable(let issue):
            destinationIssue = issue
            statusMessage = message(for: issue, folder: "destination")
        }
    }

    private func discoverSource(token: UInt64) async {
        let result = await service.discoverSource()
        guard isCurrent(token) else { return }
        sourceConfirmedByUser = false
        switch result {
        case .known(let url):
            isSourceLocationUnknown = false
            if let sourceURL, sourceURL.standardizedFileURL.path != url.standardizedFileURL.path {
                sourceIssue = .changed
                requiresSourceSelection = true
                statusMessage = "The screenshot source appears to have changed. Choose the current folder explicitly, then confirm it."
            } else {
                sourceURL = url
                sourceConfirmedByUser = false
                sourceIssue = nil
                requiresSourceSelection = false
                statusMessage = "This folder is recorded in the macOS screenshot preferences. Confirm the current Save to choice before checking access."
            }
        case .unknown:
            isSourceLocationUnknown = true
            statusMessage = "ShotDrop could not determine the current screenshot folder. Choose that folder yourself or retry."
        }
    }

    private func inspectReadiness(token: UInt64) async {
        guard let sourceURL, let destinationURL, sourceConfirmedByUser else { return }
        let sourceResult = await service.checkSource(sourceURL, expecting: expectedSourceIdentity)
        guard isCurrent(token) else { return }
        let sourceIdentity: ShotDropSetupDirectoryIdentity
        switch sourceResult {
        case .accessible(let identity):
            sourceIdentity = identity
            sourceIssue = nil
            expectedSourceIdentity = identity
        case .unavailable(let issue):
            sourceIssue = issue
            statusMessage = message(for: issue, folder: "screenshot source")
            return
        }
        let destinationResult = await service.checkDestination(destinationURL, source: sourceURL,
                                                               sourceIdentity: sourceIdentity)
        guard isCurrent(token) else { return }
        let destinationIdentity: ShotDropSetupDirectoryIdentity
        switch destinationResult {
        case .needsReview(let identity):
            destinationIdentity = identity
            destinationIssue = nil
        case .unavailable(let issue):
            destinationIssue = issue
            statusMessage = message(for: issue, folder: "destination")
            return
        }
        let binding = ShotDropSetupReadinessBinding(source: sourceIdentity, destination: destinationIdentity)
        let decision = await gate.evaluate(binding)
        guard isCurrent(token) else { return }
        guard decision.permitsTest(for: binding) else {
            destinationNeedsReview = true
            statusMessage = "Automatic copying and saving are not available in this build. Your save destination can be kept for later."
            return
        }
        verifiedBinding = binding
        readiness = decision
        destinationNeedsReview = false
        step = .test
        statusMessage = "Use Shift-Command-3 or Shift-Command-4 to take a test screenshot."
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        generation == token && isPresented && !Task.isCancelled
    }

    private func invalidate() {
        generation &+= 1
        operation?.cancel()
        operation = nil
        isBusy = false
        verifiedBinding = nil
        readiness = nil
    }

    private func message(for issue: ShotDropSetupAccessIssue, folder: String) -> String {
        switch issue {
        case .missing: "The \(folder) is missing. Choose its current location and retry."
        case .denied: "ShotDrop could not access the \(folder). Review access and retry."
        case .changed: "The \(folder) moved or changed. Choose and confirm its current location again."
        case .unsupported: "This \(folder) is not supported for safe setup. Choose a supported local folder."
        case .unsafe: "Choose separate screenshot source and destination folders."
        case .unavailable: "The \(folder) could not be checked. Retry when it is available."
        }
    }
}
