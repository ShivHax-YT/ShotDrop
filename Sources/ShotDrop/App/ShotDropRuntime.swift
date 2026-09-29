import AppKit
import Observation

@MainActor @Observable
final class ShotDropRuntime {
    let settings: AppSettings
    let history: RecentHistoryStore
    let recents: RecentMenuController
    private var pipeline: ScreenshotPipeline?
    private var detector: ScreenshotDetector?
    private var lifecycle: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var session = UUID()
    private var transition = UUID()
    private var outcomeTask: Task<Void, Never>?
    private(set) var isRunning = false
    private(set) var status = "Finish setup to start copying and saving"
    private let saves = ScreenshotSaveService(organizer: ScreenshotOrganizer(fileSystem: DirectScreenshotFileSystem()))
    @ObservationIgnored lazy var capture = ShotDropCaptureController(settings: settings, status: { [weak self] in self?.setStatus($0) })
    @ObservationIgnored private lazy var thumbnailActions = PinScreenshotActions(
        writer: AppKitScreenshotPasteboardWriter(pasteboard: .general), beginClipboardIntent: { [weak self] in
            guard let self else { return { throw CancellationError() } }
            let session = self.session
            let clipboardCount = NSPasteboard.general.changeCount
            return { [weak self] in
                guard self?.session == session, NSPasteboard.general.changeCount == clipboardCount else {
                    throw CancellationError()
                }
            }
        })
    @ObservationIgnored private lazy var thumbnail = ShotDropThumbnailController(settings: settings,
        action: { [weak self] snapshot, action in
            guard let self else { return .init(status: "ShotDrop stopped.", fileActionsAvailable: false) }
            let copying = action == .copyImage || action == .copyFile
            if copying { self.recents.textCopy.cancel(); self.pipeline?.manualCopyWillBegin() }
            defer { if copying { self.pipeline?.manualCopyDidFinish() } }
            return await self.thumbnailActions.perform(snapshot, action: action)
        }, textCopy: recents.textCopy, history: history, manualCopyIntent: { [weak self] in
            self?.pipeline?.manualCopyWillBegin()
            self?.pipeline?.manualCopyDidFinish()
        })

    init(settings: AppSettings, history: RecentHistoryStore, recents: RecentMenuController) {
        self.settings = settings; self.history = history; self.recents = recents
        recents.onRetrySave = { [weak self] record in await self?.retrySave(record) }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspend() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resume() }
            })
        }
    }

    func setStatus(_ value: String) { status = value; recents.status = value }
    func togglePause() {
        settings.isPaused.toggle()
        if settings.isPaused { suspend(message: "Paused · Originals stay in the screenshot folder") }
        else { resume() }
    }
    func suspend(message: String = "Paused while the display sleeps") {
        transition = UUID()
        lifecycle?.cancel()
        lifecycle = Task { [weak self] in await self?.stop(); self?.setStatus(message) }
    }
    func resume() {
        guard settings.hasCompletedSetup, !settings.isPaused, !settings.sourcePath.isEmpty else { return }
        lifecycle?.cancel()
        lifecycle = Task { [weak self] in
            guard let self else { return }
            let access = ProductionSetupAccess()
            let source = URL(fileURLWithPath: settings.sourcePath)
            let destination = URL(fileURLWithPath: settings.destinationPath)
            guard case .accessible(let sourceID) = await access.checkSource(source, expecting: nil),
                  case .needsReview(let destinationID) = await access.checkDestination(destination, source: source, sourceIdentity: sourceID),
                  !Task.isCancelled else {
                await stop(); setStatus("Folder access needs attention · Open Setup"); return
            }
            _ = await start(.init(source: sourceID, destination: destinationID))
        }
    }
    func shutdown() async {
        lifecycle?.cancel()
        capture.stop()
        await stop()
        thumbnail.stop()
        recents.closeAllPins()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
    func stop() async {
        session = UUID(); isRunning = false
        let old = pipeline; pipeline = nil
        await old?.stop()
        await outcomeTask?.value
        detector = nil; thumbnail.dismiss()
    }

    func start(_ binding: ShotDropSetupReadinessBinding) async -> Bool {
        let transitionID = UUID(); transition = transitionID
        await stop()
        guard transition == transitionID, !Task.isCancelled else { return false }
        let token = UUID(); session = token
        let source = URL(fileURLWithPath: binding.source.path)
        let destination = URL(fileURLWithPath: binding.destination.path)
        settings.sourcePath = source.path; settings.destinationPath = destination.path
        settings.isPaused = false
        let access = ProductionSetupAccess()
        let relay = ScreenshotDetectionRelay()
        let detector = ScreenshotDetector(onStatus: { [weak self] state in
            if case .failed(let reason) = state {
                Task { @MainActor in
                    guard let self, self.session == token else { return }
                    await self.stop(); self.setStatus(reason + " · Open Setup to retry")
                }
            }
        }, onScreenshot: { relay.emit($0) })
        self.detector = detector
        let saves = saves
        let pipeline = ScreenshotPipeline(writer: AppKitScreenshotPasteboardWriter(pasteboard: .general),
            mode: settings.copyMode, modeProvider: { [weak settings] in settings?.copyMode ?? .both },
            authorizeSource: {
                guard case .accessible = await access.checkSource(source, expecting: binding.source),
                      case .needsReview(let current) = await access.checkDestination(destination, source: source, sourceIdentity: binding.source),
                      current == binding.destination else { throw CocoaError(.fileReadNoPermission) }
            }, startDetector: { callback in relay.set(callback); try await detector.start(in: source) },
            stopDetector: { await detector.stop(); relay.set(nil) },
            registerOutput: { await detector.ignoreOutput(token: $0) },
            request: { [settings] event in
                .init(organization: .init(sourceURL: event.url, destinationRoot: destination,
                    template: settings.renameTemplate,
                    namingContext: .init(appName: NSWorkspace.shared.frontmostApplication?.localizedName ?? "Screenshot",
                                         capturedAt: Date(), timeZone: .current),
                    organizeByDate: settings.organizeByDate, expectedIdentity: event.identity),
                    sourceDirectoryURL: source, destinationAccess: .userApproved)
            }, save: { request, before in await saves.save(request, beforePublishing: before) },
            allowSurvivingOriginalFallback: true,
            onOutcome: { [weak self] outcome in
                guard let self else { return }
                let prior = self.outcomeTask
                self.outcomeTask = Task { await prior?.value; await self.record(outcome, token: token) }
            })
        self.pipeline = pipeline
        do {
            try await pipeline.start(sourceAccessExplained: true)
            guard session == token, !Task.isCancelled else { await pipeline.stop(); return false }
            isRunning = true; setStatus("Ready · New screenshots are copied and saved")
            capture.registerShortcuts()
            return true
        } catch {
            await pipeline.stop()
            if session == token { isRunning = false; setStatus("Could not start: \(error.localizedDescription)") }
            return false
        }
    }

    private func retrySave(_ record: RecentHistoryRecord) async {
        guard isRunning, let reference = record.sourceReference else { setStatus("Resume ShotDrop and check setup before retrying."); return }
        let resolved = await Task.detached { RecentFileResolver().resolve(reference) }.value
        guard case .available(let source) = resolved else { setStatus("The original changed or is unavailable."); return }
        let token = session
        let request = ScreenshotSaveRequest(organization: .init(sourceURL: source.url,
            destinationRoot: URL(fileURLWithPath: settings.destinationPath), template: settings.renameTemplate,
            namingContext: .init(appName: "Screenshot", capturedAt: record.detectionDate, timeZone: .current),
            organizeByDate: settings.organizeByDate, expectedIdentity: source.liveIdentity),
            sourceDirectoryURL: URL(fileURLWithPath: settings.sourcePath), destinationAccess: .userApproved)
        let saved = await saves.save(request)
        var copied = ScreenshotPipelineCopyOutcome.notAttempted("No verified saved copy")
        if case .saved(let receipt) = saved, token == session {
            pipeline?.manualCopyWillBegin()
            defer { pipeline?.manualCopyDidFinish() }
            do {
                let prepared = try await ScreenshotClipboardPreparer().prepare(.init(sourceURL: receipt.destinationURL,
                    mode: settings.copyMode, expectedIdentity: receipt.destinationIdentity,
                    survivingFileURL: receipt.destinationURL, survivingFileIdentity: receipt.destinationIdentity))
                copied = .copied(try await ScreenshotClipboardPublisher(writer: AppKitScreenshotPasteboardWriter(pasteboard: .general))
                    .publish(prepared) { guard self.session == token else { throw CancellationError() } })
            } catch { copied = .failed(error.localizedDescription) }
        }
        await self.record(.init(captureID: record.captureID, sessionID: token, observationSequence: record.pipelineSequence,
                               sourceURL: source.url, save: saved, copy: copied), token: token)
    }

    private func record(_ outcome: ScreenshotPipelineOutcome, token: UUID) async {
        let saved: ScreenshotOrganizationResult?
        if case .saved(let receipt) = outcome.save { saved = receipt } else { saved = nil }
        let copied: Bool
        if case .copied = outcome.copy { copied = true } else { copied = false }
        do {
            let source = outcome.sourceURL
            let output = saved?.destinationURL
            let references = await Task.detached(priority: .utility) {
                (try? RecentFileReference.capture(at: source, role: .source),
                 output.flatMap { try? RecentFileReference.capture(at: $0, role: .savedCopy) })
            }.value
            let record = try await history.admit(captureID: outcome.captureID, pipelineSequence: outcome.observationSequence,
                detectionDate: outcome.observedAt, displayName: (output ?? source).lastPathComponent, sourceReference: references.0)
            let updated = try await history.update(captureID: record.captureID, expectedRevision: record.revision,
                change: .init(copyOutcome: copied ? .success : .failure,
                              saveOutcome: references.1 != nil ? .success : .failure, savedReference: references.1))
            guard token == session else { return }
            await recents.reload()
            if let reference = updated.savedReference {
                thumbnail.present(identity: .init(captureID: updated.captureID, revision: updated.revision, reference: reference), copyFailed: !copied)
                if settings.playSound { NSSound(named: "Pop")?.play() }
                setStatus(copied ? "Copied and saved · \(updated.displayName)" : "Saved · Clipboard unchanged or unavailable")
            } else if case .failed(let failure) = outcome.save { setStatus(failure.message) }
        } catch { if token == session { setStatus("Screenshot processed, but history could not be updated: \(error.localizedDescription)") } }
    }
}

private final class ScreenshotDetectionRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (DetectedScreenshot) -> Void)?
    func set(_ value: (@Sendable (DetectedScreenshot) -> Void)?) { lock.lock(); callback = value; lock.unlock() }
    func emit(_ event: DetectedScreenshot) { lock.lock(); let value = callback; lock.unlock(); value?(event) }
}
