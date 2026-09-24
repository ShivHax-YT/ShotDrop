import AppKit
import Observation

/// Owns only the visible menu state. Every file action resolves its bookmark again.
@MainActor
@Observable
final class RecentMenuController {
    typealias RowValidator = @Sendable (UUID, RecentFileReference) async throws -> RecentRowValidation
    private let history: RecentHistoryStore
    private let previews: RecentPreviewCache
    private let validateRow: RowValidator
    private let settings: AppSettings
    @ObservationIgnored private lazy var pinCoordinator = makePinCoordinator()
    @ObservationIgnored private lazy var pinManager = PinManagerWindow()
    private(set) var pinItems: [PinScreenshotCoordinator.Item] = []
    private(set) var pinFeedback: [UUID: String] = [:]
    private let annotationEditor = AnnotationEditorCoordinator()
    private let annotationAdmission: ((AnnotationSessionIdentity) -> Bool)?
    @ObservationIgnored private lazy var annotationRecents = AnnotationRecentsRecoveryCoordinator(history: history)
    private var annotationTask: Task<Void, Never>?
    private var annotationToken: UUID?
    private(set) var annotationFeedback: [UUID: String] = [:]
    private var records: [UUID: RecentHistoryRecord] = [:]
    private var rowTasks: [UUID: Task<Void, Never>] = [:]
    private var rowValidationTokens: [UUID: UUID] = [:]
    private var visibleRows: Set<UUID> = []
    private var generation: UInt64 = 0
    private var clipboardGeneration: UInt64 = 0
    let textCopy = ScreenshotTextCopyController(writer: AppKitScreenshotPasteboardWriter(pasteboard: .general))

    private(set) var rows: [RecentMenuRow] = []
    private(set) var status = "Saving paused · Developer review required"
    private(set) var historyUnavailable = false

    init(settings: AppSettings, history: RecentHistoryStore = RecentHistoryStore(),
         previews: RecentPreviewCache = RecentPreviewCache(), rowValidator: RowValidator? = nil,
         annotationAdmission: ((AnnotationSessionIdentity) -> Bool)? = nil) {
        self.annotationAdmission = annotationAdmission
        self.settings = settings
        self.history = history
        self.previews = previews
        self.validateRow = rowValidator ?? { id, reference in
            try await previews.validateRow(captureID: id, reference: reference)
        }
    }

    func panelVisible(_ visible: Bool) {
        if visible {
            Task { await reload() }
        } else {
            textCopy.cancel()
            generation &+= 1
            visibleRows.removeAll()
            for task in rowTasks.values { task.cancel() }
            rowTasks.removeAll()
            rowValidationTokens.removeAll()
            rows = rows.compactMap { records[$0.id].map(Self.makeRow) }
            Task { await previews.panelDidClose() }
        }
    }

    func rowVisible(_ id: UUID, _ visible: Bool) {
        if visible {
            visibleRows.insert(id)
            checkRow(id)
        } else {
            visibleRows.remove(id)
            rowValidationTokens.removeValue(forKey: id)
            rowTasks.removeValue(forKey: id)?.cancel()
            if let record = records[id] { updateRow(id) { _ in Self.makeRow(record) } }
        }
    }

    func reload() async {
        let requestGeneration = generation
        do {
            let snapshot = try await history.snapshot()
            guard generation == requestGeneration else { return }
            historyUnavailable = false
            let updatedRecords = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.captureID, $0) })
            pinFeedback = pinFeedback.filter { records[$0.key] == updatedRecords[$0.key] && updatedRecords[$0.key] != nil }
            records = updatedRecords
            textCopy.retain(Set(records.keys))
            annotationFeedback = annotationFeedback.filter { records[$0.key] != nil }
            rows = snapshot.records.map(Self.makeRow)
            for id in visibleRows { checkRow(id) }
        } catch {
            guard generation == requestGeneration else { return }
            historyUnavailable = true
            for task in rowTasks.values { task.cancel() }
            rowTasks.removeAll()
            rowValidationTokens.removeAll()
            records.removeAll()
            pinFeedback.removeAll()
            textCopy.retain([])
            rows = []
        }
    }

    func clearHistory() {
        textCopy.cancel()
        Task {
            do {
                try await history.clear()
                generation &+= 1
                for task in rowTasks.values { task.cancel() }
                rowTasks.removeAll()
                rowValidationTokens.removeAll()
                records.removeAll()
                pinFeedback.removeAll()
                rows = []
                historyUnavailable = false
                await previews.clear()
                status = "Recent history cleared · Files kept"
            } catch {
                status = "History could not be cleared"
            }
        }
    }

    func perform(_ id: UUID, _ action: RecentMenuAction) {
        guard let record = records[id], rows.first(where: { $0.id == id })?.allows(action) == true else { return }
        if action == .pin {
            guard let reference = record.savedReference, reference.role == .savedCopy else { return }
            pinFeedback[id] = nil
            Task {
                let latest = try? await history.snapshot()
                guard latest?.records.first(where: { $0.captureID == id }) == record, records[id] == record else {
                    if records[id] == record {
                        pinFeedback[id] = "This saved entry changed. Refresh Recents and try Pin again."
                    }
                    return
                }
                await pinCoordinator.pin(.init(captureID: id, revision: record.revision, reference: reference), filename: record.displayName)
            }
            return
        }
        if action == .annotate {
            guard let reference = record.savedReference, reference.role == .savedCopy else { return }
            annotationTask?.cancel()
            let token = UUID()
            annotationToken = token
            annotationFeedback[id] = nil
            annotationTask = Task {
                let latest = try? await history.snapshot()
                guard !Task.isCancelled, annotationToken == token else { return }
                defer { annotationTask = nil; annotationToken = nil }
                guard latest?.records.first(where: { $0.captureID == id }) == record,
                      records[id] == record else {
                    annotationFeedback[id] = "This saved entry changed. Refresh Recents and try Annotate again."
                    return
                }
                let identity = AnnotationSessionIdentity(captureID: id, revision: record.revision, reference: reference)
                let admitted = annotationAdmission?(identity) ?? annotationEditor.open(identity: identity, openRecents: { [weak owner = self] in
                    owner?.annotationRecents.show()
                })
                if !admitted {
                    annotationFeedback[id] = annotationEditor.admissionMessage
                        ?? "You can edit up to 3 screenshots. Close an annotation window to open another."
                }
            }
            return
        }
        if action == .cancelCopyText {
            if textCopy.activeID == id { textCopy.cancel() }
            return
        }
        if action == .copyText {
            guard rows.first(where: { $0.id == id })?.availability == .saved else { return }
            let requestGeneration = generation
            if textCopy.start(record, isCurrent: { [weak self] expected in
                guard let self, self.generation == requestGeneration,
                      self.records[id] == expected,
                      let snapshot = try? await self.history.snapshot() else { return false }
                return self.generation == requestGeneration && self.records[id] == expected
                    && snapshot.records.first(where: { $0.captureID == id }) == expected
            }) { clipboardGeneration &+= 1 }
            return
        }
        if action == .copyPreferred || action == .copyImage || action == .copyFile {
            clipboardGeneration &+= 1
            textCopy.cancel()
        }
        let clipboardToken = clipboardGeneration
        if action == .retryFileCheck { checkRow(id); return }
        if action == .removeFromRecents {
            guard rows.first(where: { $0.id == id })?.availability == .missing else { return }
            Task {
                do {
                    try await history.remove(captureID: id, expectedRevision: record.revision)
                    generation &+= 1
                    rowTasks.removeValue(forKey: id)?.cancel()
                    await previews.invalidate(captureID: id)
                    await reload()
                } catch { status = "Entry changed; try again" }
            }
            return
        }
        guard let reference = action == .revealOriginal ? record.sourceReference : record.savedReference,
              reference.role == (action == .revealOriginal ? .source : .savedCopy) else {
            status = "No verified file for this action"
            return
        }
        let requestGeneration = generation
        Task {
            let result = await resolveRecent(reference)
            guard generation == requestGeneration, records[id]?.revision == record.revision else { return }
            switch result {
            case .unavailable(let issue):
                markUnavailable(id, issue: issue)
            case .available(let file):
                guard file.role == reference.role else { return }
                if let refreshed = file.refreshedReference {
                    do {
                        let change = reference.role == .savedCopy
                            ? RecentHistoryChange(savedReference: refreshed)
                            : RecentHistoryChange(sourceReference: refreshed)
                        let updated = try await history.update(captureID: id,
                                                               expectedRevision: record.revision,
                                                               change: change)
                        guard generation == requestGeneration else { return }
                        records[id] = updated
                    } catch {
                        status = "Entry changed; try again"
                        return
                    }
                }
                switch action {
                case .open:
                    if !NSWorkspace.shared.open(file.url) { status = "Could not open screenshot" }
                case .revealSaved, .revealOriginal:
                    if !NSWorkspace.shared.selectFile(file.url.path, inFileViewerRootedAtPath: "") {
                        status = "Could not reveal screenshot in Finder"
                    }
                case .copyPreferred, .copyImage, .copyFile:
                    await copy(file, id: id, mode: copyMode(for: action), generation: requestGeneration,
                               clipboardToken: clipboardToken)
                case .copyText, .cancelCopyText, .annotate, .pin, .retryFileCheck, .removeFromRecents: break
                }
            }
        }
    }

    private func makePinCoordinator() -> PinScreenshotCoordinator {
        let actions = PinScreenshotActions(writer: AppKitScreenshotPasteboardWriter(pasteboard: .general), beginClipboardIntent: { [weak self] in
            guard let self else { return { throw CancellationError() } }
            self.clipboardGeneration &+= 1; self.textCopy.cancel()
            let token = self.clipboardGeneration
            return { [weak self] in
                guard self?.clipboardGeneration == token else { throw CancellationError() }
            }
        })
        let coordinator = PinScreenshotCoordinator(action: { snapshot, action in
            await actions.perform(snapshot, action: action)
        })
        coordinator.onFeedback = { [weak self] identity, feedback in
            guard let self, let current = self.records[identity.captureID],
                  current.revision == identity.revision, current.savedReference == identity.reference else { return }
            self.pinFeedback[identity.captureID] = feedback.message
        }
        coordinator.onChange = { [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            self.pinItems = coordinator.items
            self.pinManager.update(self.pinItems)
        }
        coordinator.onManagePins = { [weak self] in self?.showPins() }
        coordinator.onOpenRecents = { [weak self] in self?.annotationRecents.show() }
        coordinator.onCapacityReached = { [weak self] in self?.showPins() }
        return coordinator
    }
    func showPin(_ id: UUID) { pinCoordinator.show(id) }
    func closePin(_ id: UUID) { pinCoordinator.close(id) }
    func closeAllPins() { pinCoordinator.closeAll() }
    func showPins() {
        pinManager.onShow = { [weak self] in self?.showPin($0) }
        pinManager.onClose = { [weak self] in self?.closePin($0) }
        pinManager.onCloseAll = { [weak self] in self?.closeAllPins() }
        pinManager.update(pinItems); pinManager.show()
    }

    func currentAnnotationRequest() -> Task<Void, Never>? { annotationTask }

    private func copyMode(for action: RecentMenuAction) -> CopyMode {
        switch action {
        case .copyImage: .image
        case .copyFile: .file
        default: settings.copyMode
        }
    }

    private func copy(_ file: RecentResolvedFile, id: UUID, mode: CopyMode,
                      generation requestGeneration: UInt64, clipboardToken: UInt64) async {
        guard file.role == .savedCopy, let expectedRevision = records[id]?.revision else { return }
        do {
            let request = ScreenshotClipboardRequest(sourceURL: file.url, mode: mode,
                expectedIdentity: file.liveIdentity, survivingFileURL: file.url,
                survivingFileIdentity: file.liveIdentity)
            let prepared = try await ScreenshotClipboardPreparer().prepare(request)
            guard generation == requestGeneration, clipboardGeneration == clipboardToken else { return }
            let latest = try await history.snapshot()
            guard latest.records.first(where: { $0.captureID == id })?.revision == expectedRevision,
                  records[id]?.revision == expectedRevision else { return }
            _ = try await ScreenshotClipboardPublisher(writer:
                AppKitScreenshotPasteboardWriter(pasteboard: .general)).publish(prepared) {
                    guard self.generation == requestGeneration,
                          self.clipboardGeneration == clipboardToken,
                          self.records[id]?.revision == expectedRevision else {
                        throw RecentHistoryStoreError.staleRevision
                    }
                }
            updateRow(id) { row in
                RecentMenuRow(id: row.id, displayName: row.displayName, detectedAt: row.detectedAt,
                    detail: row.detail, availability: row.availability, savedPath: row.savedPath,
                    sourcePath: row.sourcePath, previewImage: row.previewImage,
                    copyConfirmation: mode)
            }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard generation == requestGeneration else { return }
                updateRow(id) { row in
                    RecentMenuRow(id: row.id, displayName: row.displayName, detectedAt: row.detectedAt,
                        detail: row.detail, availability: row.availability, savedPath: row.savedPath,
                        sourcePath: row.sourcePath, previewImage: row.previewImage,
                        copyConfirmation: nil)
                }
            }
        } catch {
            status = "Screenshot could not be copied"
        }
    }

    private func checkRow(_ id: UUID) {
        rowValidationTokens.removeValue(forKey: id)
        rowTasks.removeValue(forKey: id)?.cancel()
        guard visibleRows.contains(id), let record = records[id],
              let reference = record.savedReference ?? record.sourceReference else { return }
        let token = UUID()
        rowValidationTokens[id] = token
        updateRow(id) { _ in Self.makeRow(record) }
        let requestGeneration = generation
        rowTasks[id] = Task {
            defer {
                if rowValidationTokens[id] == token {
                    rowValidationTokens.removeValue(forKey: id)
                    rowTasks.removeValue(forKey: id)
                }
            }
            let result: RecentRowValidation
            do { result = try await validateRow(id, reference) }
            catch {
                guard rowValidationTokens[id] == token, generation == requestGeneration,
                      visibleRows.contains(id), records[id]?.revision == record.revision else { return }
                let detail: String
                if error is CancellationError { detail = "File check cancelled · Retry File Check" }
                else if error as? RecentPreviewError == .queueFull { detail = "File check busy · Retry File Check" }
                else { detail = "File check unavailable · Retry File Check" }
                updateRow(id) { row in
                    RecentMenuRow(id: row.id, displayName: row.displayName, detectedAt: row.detectedAt,
                        detail: detail, availability: .unavailable, savedPath: row.savedPath,
                        sourcePath: row.sourcePath, previewImage: nil, copyConfirmation: nil)
                }
                return
            }
            guard !Task.isCancelled, generation == requestGeneration,
                  rowValidationTokens[id] == token,
                  visibleRows.contains(id), records[id]?.revision == record.revision else { return }
            switch result {
            case .unavailable(let issue): markUnavailable(id, issue: issue)
            case .available(let image, let refreshedReference):
                textCopy.clearUnavailable(id)
                updateRow(id) { row in
                    RecentMenuRow(id: row.id, displayName: row.displayName,
                        detectedAt: row.detectedAt, detail: reference.role == .savedCopy ? "Saved copy" : "Original only",
                        availability: reference.role == .savedCopy ? .saved : .sourceOnly, savedPath: row.savedPath,
                        sourcePath: row.sourcePath, previewImage: image,
                        copyConfirmation: row.copyConfirmation)
                }
                if let refreshed = refreshedReference {
                    let change = reference.role == .savedCopy
                        ? RecentHistoryChange(savedReference: refreshed)
                        : RecentHistoryChange(sourceReference: refreshed)
                    if let updated = try? await history.update(captureID: id,
                        expectedRevision: record.revision, change: change),
                        !Task.isCancelled, generation == requestGeneration,
                        rowValidationTokens[id] == token,
                        visibleRows.contains(id), records[id]?.revision == record.revision {
                        records[id] = updated
                    }
                }
            }
        }
    }

    /// Captures the current completion for lifecycle tests without starting work.
    func currentRowValidation(_ id: UUID) -> Task<Void, Never>? { rowTasks[id] }

    private func markUnavailable(_ id: UUID, issue: RecentFileIssue) {
        let availability: RecentMenuRow.Availability = issue == .missing ? .missing : .unavailable
        let detail: String
        switch issue {
        case .missing: detail = records[id]?.savedReference == nil ? "Original missing" : "Saved file missing"
        case .offline: detail = "Drive offline"
        case .denied: detail = "Access denied"
        case .replaced: detail = "File changed"
        case .needsLocation: detail = "File needs locating"
        }
        updateRow(id) { row in
            RecentMenuRow(id: row.id, displayName: row.displayName, detectedAt: row.detectedAt,
                detail: detail, availability: availability, savedPath: row.savedPath,
                sourcePath: row.sourcePath, previewImage: nil, copyConfirmation: nil)
        }
    }

    private func updateRow(_ id: UUID, _ transform: (RecentMenuRow) -> RecentMenuRow) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index] = transform(rows[index])
    }

    private static func makeRow(_ record: RecentHistoryRecord) -> RecentMenuRow {
        let availability: RecentMenuRow.Availability = record.savedReference != nil || record.sourceReference != nil
            ? .checking : .unavailable
        let detail = record.savedReference != nil ? "Checking saved copy…" :
            record.sourceReference != nil ? "Checking original…" : "File unavailable"
        return RecentMenuRow(id: record.captureID, displayName: record.displayName,
            detectedAt: record.detectionDate, detail: detail, availability: availability,
            savedPath: record.savedReference?.lastKnownPath,
            sourcePath: record.sourceReference?.lastKnownPath,
            previewImage: nil, copyConfirmation: nil)
    }
}

@concurrent
private func resolveRecent(_ reference: RecentFileReference) async -> RecentFileResolution {
    RecentFileResolver().resolve(reference)
}
