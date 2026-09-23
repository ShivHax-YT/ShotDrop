import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class AnnotationRecentsRecoveryModel {
    private(set) var records: [RecentHistoryRecord] = []
    private(set) var busy = false
    private(set) var message = "" { didSet { if active, message != oldValue { announceResult?(message) } } }
    var announceResult: ((String) -> Void)?
    private var active = false
    private var job: Task<Void, Never>?
    private let loadRecords: @Sendable () async throws -> [RecentHistoryRecord]
    private let resolve: @Sendable (RecentFileReference) async -> RecentFileResolution
    private let reveal: @MainActor (URL) -> Bool

    init(history: RecentHistoryStore,
         loadRecords: (@Sendable () async throws -> [RecentHistoryRecord])? = nil,
         resolve: @escaping @Sendable (RecentFileReference) async -> RecentFileResolution = resolveAnnotationRecoveryFile,
         reveal: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.selectFile($0.path, inFileViewerRootedAtPath: "") }) {
        self.loadRecords = loadRecords ?? { try await history.snapshot().records }
        self.resolve = resolve
        self.reveal = reveal
    }

    func open() {
        active = true
        guard job == nil else { message = "Finishing the previous check…"; return }
        busy = true
        message = "Loading recent screenshots…"
        job = Task { [weak self, loadRecords] in
            do {
                let records = try await loadRecords()
                guard let self, self.active, !Task.isCancelled else { self?.finish(); return }
                self.records = Array(records.prefix(20))
                self.message = records.isEmpty ? "No recent screenshots are recorded." : "Locations are historical. Reveal checks the saved copy before opening Finder."
            } catch {
                if let self, self.active, !Task.isCancelled { self.message = "Recent screenshots could not be loaded." }
            }
            self?.finish()
        }
    }

    func revealSavedCopy(_ id: UUID) {
        guard active, job == nil,
              let reference = records.first(where: { $0.id == id })?.savedReference,
              reference.role == .savedCopy else { return }
        busy = true
        message = "Checking saved copy…"
        job = Task { [weak self, resolve] in
            let result = await resolve(reference)
            guard let self else { return }
            defer { self.finish() }
            guard self.active, !Task.isCancelled else { return }
            switch result {
            case let .available(file):
                guard file.role == .savedCopy else {
                    self.message = "Saved copy unavailable. The original has not been substituted."
                    return
                }
                self.message = self.reveal(file.url)
                    ? "Asked Finder to reveal the verified saved copy."
                    : "Could not reveal the saved copy in Finder. Try again or use its last saved location below."
            case .unavailable:
                self.message = "Saved copy unavailable. Its last saved location is shown below; the original has not been substituted."
            }
        }
    }

    func close() { active = false; job?.cancel() }
    func finishPendingWork() async { await job?.value }

    private func finish() {
        let reload = active && job?.isCancelled == true
        job = nil
        busy = false
        if reload { open() }
    }
}

@concurrent
private func resolveAnnotationRecoveryFile(_ reference: RecentFileReference) async -> RecentFileResolution {
    RecentFileResolver().resolve(reference)
}

@MainActor
final class AnnotationRecentsRecoveryCoordinator: NSObject, NSWindowDelegate {
    private let model: AnnotationRecentsRecoveryModel
    private var window: NSWindow?

    init(history: RecentHistoryStore) { model = AnnotationRecentsRecoveryModel(history: history) }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Recent Screenshots"
        window.minSize = NSSize(width: 440, height: 320)
        window.isReleasedWhenClosed = false
        window.delegate = self
        model.announceResult = { [weak window] message in
            guard let window, window.isVisible else { return }
            NSAccessibility.post(element: window, notification: .announcementRequested,
                userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        window.contentView = NSHostingView(rootView: AnnotationRecentsRecoveryView(model: model))
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        model.open()
    }

    func windowWillClose(_ notification: Notification) {
        model.close()
        window = nil
    }
}

private struct AnnotationRecentsRecoveryView: View {
    let model: AnnotationRecentsRecoveryModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Screenshots").font(.title2)
                Spacer()
                Button("Refresh Recents") { model.open() }.disabled(model.busy)
            }
            Text(model.message).font(.callout).accessibilityLabel(model.message)
            if model.busy { ProgressView().controlSize(.small) }
            List(model.records) { record in
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.displayName).font(.headline)
                    Text(record.detectionDate, style: .date).font(.caption)
                    if let reference = record.savedReference {
                        Text("Last saved location").font(.caption).foregroundStyle(.secondary)
                        Text(reference.lastKnownPath).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button("Reveal Saved Copy") { model.revealSavedCopy(record.id) }
                            .disabled(model.busy)
                            .accessibilityLabel("Reveal saved copy of \(record.displayName)")
                    } else { Text("No saved copy is recorded.").foregroundStyle(.secondary) }
                }.padding(.vertical, 6)
            }
        }.padding(20)
    }
}
