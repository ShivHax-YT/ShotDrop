import AppKit
import Observation

/// Owns only the visible menu state. Every file action resolves its bookmark again.
@MainActor
@Observable
final class RecentMenuController {
    private let history = RecentHistoryStore()
    private let previews = RecentPreviewCache()
    private let settings: AppSettings
    private var records: [UUID: RecentHistoryRecord] = [:]
    private var rowTasks: [UUID: Task<Void, Never>] = [:]
    private var visibleRows: Set<UUID> = []
    private var generation: UInt64 = 0
    private var clipboardGeneration: UInt64 = 0
    let textCopy = ScreenshotTextCopyController(writer: AppKitScreenshotPasteboardWriter(pasteboard: .general))

    private(set) var rows: [RecentMenuRow] = []
    private(set) var status = "Setup needed · Not watching"
    private(set) var historyUnavailable = false

    init(settings: AppSettings) { self.settings = settings }

    func panelVisible(_ visible: Bool) {
        if visible {
            Task { await reload() }
        } else {
            textCopy.cancel()
            generation &+= 1
            visibleRows.removeAll()
            for task in rowTasks.values { task.cancel() }
            rowTasks.removeAll()
            rows = rows.map { row in
                RecentMenuRow(id: row.id, displayName: row.displayName,
                    detectedAt: row.detectedAt, detail: row.detail,
                    availability: row.availability, savedPath: row.savedPath,
                    sourcePath: row.sourcePath, previewImage: nil, copyConfirmation: nil)
            }
            Task { await previews.panelDidClose() }
        }
    }

    func rowVisible(_ id: UUID, _ visible: Bool) {
        if visible {
            visibleRows.insert(id)
            checkRow(id)
        } else {
            visibleRows.remove(id)
            rowTasks.removeValue(forKey: id)?.cancel()
        }
    }

    func reload() async {
        let requestGeneration = generation
        do {
            let snapshot = try await history.snapshot()
            guard generation == requestGeneration else { return }
            historyUnavailable = false
            records = Dictionary(uniqueKeysWithValues: snapshot.records.map { ($0.captureID, $0) })
            textCopy.retain(Set(records.keys))
            rows = snapshot.records.map(Self.makeRow)
            for id in visibleRows { checkRow(id) }
        } catch {
            guard generation == requestGeneration else { return }
            historyUnavailable = true
            records.removeAll()
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
                records.removeAll()
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
        guard let record = records[id] else { return }
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
                case .copyText, .cancelCopyText, .retryFileCheck, .removeFromRecents: break
                }
            }
        }
    }

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
        rowTasks.removeValue(forKey: id)?.cancel()
        guard let record = records[id],
              let reference = record.savedReference ?? record.sourceReference else { return }
        let requestGeneration = generation
        rowTasks[id] = Task {
            let result: RecentRowValidation
            do { result = try await previews.validateRow(captureID: id, reference: reference) }
            catch { return } // Cancellation/queue pressure does not authorize a file action.
            guard !Task.isCancelled, generation == requestGeneration,
                  visibleRows.contains(id), records[id]?.revision == record.revision else { return }
            switch result {
            case .unavailable(let issue): markUnavailable(id, issue: issue)
            case .available(let image, let refreshedReference):
                textCopy.clearUnavailable(id)
                updateRow(id) { row in
                    RecentMenuRow(id: row.id, displayName: row.displayName,
                        detectedAt: row.detectedAt, detail: row.detail,
                        availability: row.availability, savedPath: row.savedPath,
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
                        visibleRows.contains(id), records[id]?.revision == record.revision {
                        records[id] = updated
                    }
                }
            }
        }
    }

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
        let availability: RecentMenuRow.Availability = record.savedReference != nil ? .saved
            : record.sourceReference != nil ? .sourceOnly : .unavailable
        let detail = record.savedReference != nil ? "Saved copy" :
            record.sourceReference != nil ? "Original only" : "File unavailable"
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
