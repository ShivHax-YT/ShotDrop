import AppKit
import SwiftUI

/// Dormant, explicit presentation endpoint. No observer/pipeline installs this controller.
/// One decode runs at a time; newer arrivals replace only the pending identity.
@MainActor
final class ShotDropThumbnailController {
    typealias ActionDriver = @MainActor (PinScreenshotSnapshot, PinScreenshotAction) async -> PinScreenshotActionResult
    private struct Request {
        let identity: PinScreenshotIdentity
        let copyFailed: Bool
        let screen: NSScreen?
    }
    private let settings: AppSettings
    private let store: PinScreenshotStore
    private let actionDriver: ActionDriver?
    private let textSession: ThumbnailTextCopySession?
    private var pending: Request?
    private var loading = false
    private var generation = UUID()
    private var visible: (UUID, PinScreenshotSnapshot)?
    private var panel: ThumbnailPanel?
    private var idleTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var isHovered = false
    private var isFocused = false
    private var isMenuOpen = false
    private var isDragging = false
    private var isSleeping = false
    private var stopped = false
    private var screen: NSScreen?
    private var locked: Bool { isFocused || isMenuOpen || isDragging || actionTask != nil || textSession?.isRunning == true }
    var onOpenRecents: (() -> Void)?
    private let dragValidation = ThumbnailDragValidation()
    private let feedback = ThumbnailFeedback()
    var status: String? { feedback.status ?? textSession?.state?.message }

    init(settings: AppSettings, store: PinScreenshotStore = PinScreenshotStore(), action: ActionDriver? = nil,
         textCopy: ScreenshotTextCopyController? = nil, history: RecentHistoryStore? = nil, manualCopyIntent: (() -> Void)? = nil) {
        self.settings = settings; self.store = store; self.actionDriver = action
        if let textCopy, let history, let manualCopyIntent {
            textSession = ThumbnailTextCopySession(controller: textCopy, history: history, manualCopyIntent: manualCopyIntent)
        } else { textSession = nil }
        textSession?.onChange = { [weak self] in
            guard let self else { return }
            if let state = self.textSession?.state, self.textSession?.identity == self.visible?.1.identity {
                if state == .recognizing { self.feedback.status = nil }
                self.panel?.contentView?.setAccessibilityHelp(state.message)
            }
            self.interactionChanged()
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.reposition() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.sleep() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.isSleeping = false } })
    }

    /// Reference must describe the verified saved revision, never a staging/source URL.
    /// Admission cannot silently bind a replacement at the old path.
    func present(identity: PinScreenshotIdentity, copyFailed: Bool = false, captureScreen: NSScreen? = nil) {
        guard !stopped, settings.showShotDropThumbnail, !isSleeping, identity.reference.role == .savedCopy else { return }
        guard visible?.1.identity != identity else { return }
        pending = Request(identity: identity, copyFailed: copyFailed, screen: captureScreen ?? inferredScreen())
        textSession?.cancel()
        startPending()
    }

    private func startPending() {
        guard !loading, !locked, !stopped, !isSleeping, let request = pending else { return }
        pending = nil; loading = true
        idleTask?.cancel(); idleTask = nil
        let session = generation
        Task { [weak self, store] in
            var token: UUID?
            do {
                switch try await store.admit(request.identity) {
                case .opened(let value), .existing(let value): token = value
                case .closing, .full: throw PinScreenshotFailure.budgetExceeded
                }
                guard let token else { throw PinScreenshotFailure.unavailable }
                let snapshot = try await store.snapshot(for: token)
                guard let self else { await store.close(token); return }
                if self.generation != session || self.stopped || self.isSleeping || !self.settings.showShotDropThumbnail {
                    await store.close(token)
                } else if self.pending != nil || self.locked {
                    // Do not interrupt a deliberate interaction. No decoded pending cache.
                    if self.pending == nil { self.pending = request }
                    await store.close(token)
                } else {
                    let old = self.visible?.0
                    self.visible = (token, snapshot)
                    self.screen = request.screen
                    self.show(snapshot, copyFailed: request.copyFailed)
                    if let old, old != token { await store.close(old) }
                }
            } catch {
                if let token { await store.close(token) }
                if let self, self.generation == session { self.feedback.status = "Saved screenshot unavailable or changed. Open Recents to recover it." }
            }
            guard let self else { return }
            self.loading = false
            self.startPending()
            self.updateIdle()
        }
    }

    func dismiss() {
        generation = UUID()
        textSession?.bind(nil)
        idleTask?.cancel(); idleTask = nil
        actionTask?.cancel() // Keep the operation slot until its worker returns.
        if let token = visible?.0 { Task { [store] in await store.close(token) } }
        visible = nil
        panel?.orderOut(nil); panel?.contentView = nil
        isHovered = false; isFocused = false; isMenuOpen = false; isDragging = false
        startPending()
    }

    func stop() {
        stopped = true; pending = nil; dismiss()
        panel = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    private func inferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
    }
    private func reposition() {
        guard let panel else { return }
        if screen == nil || !NSScreen.screens.contains(where: { $0 === screen }) { screen = inferredScreen() }
        if let screen { panel.setFrame(ThumbnailPolicy.frame(in: screen.visibleFrame), display: true) }
    }

    private func show(_ snapshot: PinScreenshotSnapshot, copyFailed: Bool) {
        guard let cg = try? AnnotationRenderer.image(raster: AnnotationRaster(width: snapshot.image.width,
                    height: snapshot.image.height, rgba: snapshot.image.rgba)) else { dismiss(); return }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        idleTask?.cancel()
        isHovered = false; isFocused = false; isMenuOpen = false; isDragging = false
        let panel = self.panel ?? ThumbnailPanel(); self.panel = panel
        let identity = snapshot.identity
        textSession?.bind(identity)
        let capture = ThumbnailCapture(id: identity.captureID,
            finalURL: URL(fileURLWithPath: identity.reference.lastKnownPath), copyFailed: copyFailed)
        panel.onEscape = { [weak self] in self?.dismiss() }
        let card = ThumbnailCard(capture: capture, image: image, feedback: feedback, textSession: textSession,
            copyImageTitle: snapshot.isReduced ? "Copy Preview Image" : "Copy Image",
            fidelity: snapshot.isReduced ? "Reduced preview · \(snapshot.image.width) × \(snapshot.image.height)" : "",
            actionsEnabled: actionDriver != nil,
            validateDrag: { [dragValidation] in try await dragValidation.resolve(identity.reference) },
            onOpen: { [weak self] in self?.perform(.open, snapshot: snapshot) },
            onCopy: { [weak self] in self?.perform(.copyImage, snapshot: snapshot) },
            onCopyFile: { [weak self] in self?.perform(.copyFile, snapshot: snapshot) },
            onReveal: { [weak self] in self?.perform(.reveal, snapshot: snapshot) },
            onDismiss: { [weak self] in self?.dismiss(identity: identity) },
            onOpenRecents: { [weak self] in self?.onOpenRecents?() },
            onHover: { [weak self] value in
                guard let self, self.visible?.1.identity == identity else { return }
                self.isHovered = value; self.updateIdle()
            },
            onFocus: { [weak self] value in
                guard let self, self.visible?.1.identity == identity else { return }
                self.isFocused = value; self.interactionChanged()
            },
            onMenu: { [weak self] value in
                guard let self, self.visible?.1.identity == identity else { return }
                self.isMenuOpen = value; self.interactionChanged()
            },
            onDrag: { [weak self] value in
                guard let self, self.visible?.1.identity == identity else { return }
                self.isDragging = value; self.interactionChanged()
            },
            onSwipe: { [weak self] in self?.dismiss(identity: identity) })
        panel.contentView = NSHostingView(rootView: card)
        reposition()
        panel.alphaValue = 1
        panel.orderFront(nil)
        feedback.status = nil
        updateIdle() // Deadline begins after the actual snapshot becomes visible.
    }

    private func dismiss(identity: PinScreenshotIdentity) {
        guard visible?.1.identity == identity else { return }; dismiss()
    }

    private func interactionChanged() { updateIdle(); startPending() }
    private func updateIdle() {
        idleTask?.cancel(); idleTask = nil
        guard let identity = visible?.1.identity, !loading, !isHovered, !locked, panel?.isVisible == true, !isSleeping else { return }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ThumbnailPolicy.idleSeconds))
            guard !Task.isCancelled, let self, self.visible?.1.identity == identity else { return }
            self.dismiss()
        }
    }
    private func sleep() { isSleeping = true; pending = nil; dismiss() }
    private func perform(_ action: PinScreenshotAction, snapshot: PinScreenshotSnapshot) {
        guard visible?.1.identity == snapshot.identity, actionTask == nil, let actionDriver else { return }
        let session = generation
        if action == .copyImage || action == .copyFile { textSession?.cancel() }
        idleTask?.cancel()
        actionTask = Task { [weak self] in
            let result = await actionDriver(snapshot, action)
            guard let self else { return }
            self.actionTask = nil
            if self.generation == session, self.visible?.1.identity == snapshot.identity {
                self.feedback.status = result.status
                self.panel?.contentView?.setAccessibilityHelp(result.status)
            }
            self.interactionChanged()
        }
    }

    @concurrent
    static func verifiedDragURL(_ reference: RecentFileReference) async throws -> URL {
        guard reference.role == .savedCopy,
              case .available(let file) = RecentFileResolver().resolve(reference), file.role == .savedCopy else {
            throw PinScreenshotFailure.unavailable
        }
        try Task.checkCancellation()
        return file.url
    }
}

private final class ThumbnailPanel: NSPanel {
    var onEscape: (() -> Void)?
    init() {
        super.init(contentRect: CGRect(origin: .zero, size: ThumbnailPolicy.maximumSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating; hidesOnDeactivate = false; isOpaque = false
        backgroundColor = .clear; hasShadow = true; becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
    override func cancelOperation(_ sender: Any?) { guard isKeyWindow else { return }; onEscape?() }
}

/// A dismissed gesture cannot open a second full-file validation worker before the
/// first descriptor read drains. All thumbnail views share this one admission slot.
@MainActor
private final class ThumbnailDragValidation {
    private var busy = false
    func resolve(_ reference: RecentFileReference) async throws -> URL {
        guard !busy else { throw PinScreenshotFailure.unavailable }
        busy = true
        defer { busy = false }
        return try await ShotDropThumbnailController.verifiedDragURL(reference)
    }
}
