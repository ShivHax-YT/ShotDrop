import AppKit

/// The same native panel is revealed differently for explicit intent and passive completion.
@MainActor
protocol PinPanelPresentationTarget: AnyObject {
    func orderFront(_ sender: Any?)
    func makeKeyAndOrderFront(_ sender: Any?)
}
extension NSPanel: PinPanelPresentationTarget {}

@MainActor
enum PinPanelPresentation {
    enum Intent { case passiveLoad, explicitShow }
    static func present(_ panel: any PinPanelPresentationTarget, intent: Intent) {
        switch intent {
        case .passiveLoad: panel.orderFront(nil)
        case .explicitShow: panel.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
private final class PinImageCanvas: NSView {
    let image: NSImage
    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

@MainActor
private final class PinReferencePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {
        if isKeyWindow { performClose(sender) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isKeyWindow, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class PinPanelContent: NSViewController {
    private let canvas: PinImageCanvas
    private let scroll = NSScrollView()
    private let sourceWidth: Int
    private let sourceHeight: Int
    private var zoom: CGFloat? = nil
    private let status: String
    private let filename: String
    private let reduced: Bool
    private let actionStatus = NSTextField(wrappingLabelWithString: "")
    private var fileMenuItems: [NSMenuItem] = []
    var actionsEnabled = false
    private var fileIdentityAvailable = true
    var onCopyImage: (() -> Void)?
    var onCopyFile: (() -> Void)?
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onOpenRecents: (() -> Void)?

    init(image: NSImage, filename: String, width: Int, height: Int, reduced: Bool) {
        canvas = PinImageCanvas(image: image)
        sourceWidth = width
        sourceHeight = height
        self.filename = filename
        self.reduced = reduced
        status = reduced ? "Reduced preview · \(Int(image.size.width)) × \(Int(image.size.height))" : "\(width) × \(height) pixels"
        super.init(nibName: nil, bundle: nil)
        canvas.setAccessibilityLabel("\(filename), \(width) by \(height) pixels")
        canvas.setAccessibilityValue(status)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        let fit = NSButton(title: "Fit", target: self, action: #selector(fitImage))
        let actual = NSButton(title: "100%", target: self, action: #selector(actualSize))
        actual.setAccessibilityLabel("Actual Size")
        let more = NSPopUpButton(frame: .zero, pullsDown: true)
        more.addItem(withTitle: "More")
        more.menu?.autoenablesItems = false
        for (title, action, fileTarget) in [
            ("Open Screenshot", #selector(openScreenshot), true),
            (reduced ? "Copy Preview Image" : "Copy Pinned Image", #selector(copyImage), false),
            ("Copy File", #selector(copyFile), true),
            ("Reveal in Finder", #selector(revealScreenshot), true),
            ("Open Recents", #selector(openRecents), false)
        ] {
            more.addItem(withTitle: title)
            more.lastItem?.target = self
            more.lastItem?.action = action
            if fileTarget, let item = more.lastItem { fileMenuItems.append(item) }
            if action != #selector(openRecents) { more.lastItem?.isEnabled = actionsEnabled }
        }
        more.addItem(withTitle: "Close Pin")
        more.lastItem?.target = self
        more.lastItem?.action = #selector(closePin)
        more.addItem(withTitle: "Zoom Out")
        more.lastItem?.target = self
        more.lastItem?.action = #selector(smaller)
        more.addItem(withTitle: "Zoom In")
        more.lastItem?.target = self
        more.lastItem?.action = #selector(larger)
        let controls = NSStackView(views: [fit, actual, more])
        controls.spacing = 4
        controls.orientation = .horizontal
        controls.distribution = .fillProportionally
        for control in [fit, actual, more] {
            control.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        }
        let label = NSTextField(wrappingLabelWithString: status)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.setAccessibilityLabel(status)
        let privacy = NSTextField(wrappingLabelWithString: "Pins stay on this desktop until closed. Visible pins may appear in screen sharing or screenshots.")
        privacy.font = .preferredFont(forTextStyle: .caption2)
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = canvas
        actionStatus.font = .preferredFont(forTextStyle: .caption1)
        for child in [controls, label, actionStatus, scroll, privacy] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            actionStatus.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
            actionStatus.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            actionStatus.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: actionStatus.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            privacy.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            privacy.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            privacy.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            privacy.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
    }
    override func viewDidLayout() { super.viewDidLayout(); updateImageSize() }
    func updateImageSize() {
        let available = scroll.contentSize
        let dimensions: CGSize
        if let zoom {
            dimensions = PinPanelGeometry.imageSize(width: sourceWidth, height: sourceHeight,
                backingScale: view.window?.backingScaleFactor ?? 1, zoom: zoom)
        } else {
            let scale = max(0, min(available.width / CGFloat(sourceWidth), available.height / CGFloat(sourceHeight)))
            dimensions = CGSize(width: CGFloat(sourceWidth) * scale, height: CGFloat(sourceHeight) * scale)
        }
        if canvas.frame.size != dimensions { canvas.setFrameSize(dimensions); canvas.needsDisplay = true }
    }
    func setActionStatus(_ message: String, fileActionsAvailable: Bool) {
        actionStatus.stringValue = message
        actionStatus.setAccessibilityLabel(message)
        fileIdentityAvailable = fileIdentityAvailable && fileActionsAvailable
        fileMenuItems.forEach { $0.isEnabled = actionsEnabled && fileIdentityAvailable }
    }
    @objc private func copyImage() { onCopyImage?() }
    @objc private func copyFile() { onCopyFile?() }
    @objc private func openScreenshot() { onOpen?() }
    @objc private func revealScreenshot() { onReveal?() }
    @objc private func openRecents() { onOpenRecents?() }
    @objc private func fitImage() { zoom = nil; updateImageSize() }
    @objc private func actualSize() { zoom = 1; updateImageSize() }
    @objc private func smaller() { zoom = max(0.25, (zoom ?? 1) / 1.25); updateImageSize() }
    @objc private func larger() { zoom = min(4, (zoom ?? 1) * 1.25); updateImageSize() }
    @objc private func closePin() { view.window?.performClose(nil) }
}

/// Session-only owner. Integrators must gate entry on a verified saved Recent revision.
/// Explicit file/clipboard actions use the injected validated driver; no permission or Spaces mutations.
@MainActor
final class PinScreenshotCoordinator: NSObject, NSWindowDelegate {
    struct Item: Identifiable {
        let id: UUID
        let filename: String
    }
    enum Feedback {
        case loading, shown, closed, closing, capacity
        case failed(String)
        var message: String? {
            switch self {
            case .loading: "Loading pinned screenshot…"
            case .shown: "Screenshot pinned."
            case .closed: nil
            case .closing: "This pin is closing. Try again when its image has finished releasing."
            case .capacity: "You can pin up to 3 screenshots. Close a pin to add another."
            case .failed(let message): message
            }
        }
    }
    typealias ActionDriver = @MainActor (PinScreenshotSnapshot, PinScreenshotAction) async -> PinScreenshotActionResult
    private let actionDriver: ActionDriver?
    private let store: PinScreenshotStore
    private var actionTasks: [UUID: Task<Void, Never>] = [:]
    private var actionGeneration: [UUID: UUID] = [:]
    private var panels: [UUID: PinReferencePanel] = [:]
    private var loads: [UUID: Task<Void, Never>] = [:]
    private var identities: [UUID: PinScreenshotIdentity] = [:]
    private var names: [UUID: String] = [:] { didSet { onChange?() } }
    private let workspaceNotifications: NotificationCenter
    var onFeedback: ((PinScreenshotIdentity, Feedback) -> Void)?
    var onChange: (() -> Void)?
    var onManagePins: (() -> Void)?
    var onOpenRecents: (() -> Void)?
    var onCapacityReached: (() -> Void)?
    private var closeAllGeneration: UInt64 = 0
    private var adjustingGeometry = false
    private(set) var status: String? { didSet { onChange?() } }
    var items: [Item] { names.map { Item(id: $0.key, filename: $0.value) }.sorted { $0.filename < $1.filename } }

    init(store: PinScreenshotStore = PinScreenshotStore(), action: ActionDriver? = nil) {
        self.actionDriver = action
        self.store = store
        workspaceNotifications = NSWorkspace.shared.notificationCenter
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        workspaceNotifications.addObserver(self, selector: #selector(displaysChanged),
            name: NSWorkspace.didWakeNotification, object: nil)
    }
    deinit {
        NotificationCenter.default.removeObserver(self)
        workspaceNotifications.removeObserver(self)
    }

    func pin(_ identity: PinScreenshotIdentity, filename: String) async {
        let generation = closeAllGeneration
        onFeedback?(identity, .loading)
        do {
            let admission = try await store.admit(identity)
            guard generation == closeAllGeneration else {
                if case .opened(let token) = admission { await store.close(token) }
                onFeedback?(identity, .closed)
                return
            }
            switch admission {
            case .existing(let token):
                show(token)
                onFeedback?(identity, panels[token] == nil ? .loading : .shown)
            case .closing:
                status = Feedback.closing.message
                onFeedback?(identity, .closing)
            case .full:
                status = Feedback.capacity.message
                onFeedback?(identity, .capacity)
                onCapacityReached?()
            case .opened(let token):
                identities[token] = identity
                names[token] = filename
                let pointer = NSEvent.mouseLocation
                loads[token] = Task { [weak self, store] in
                    do {
                        let snapshot = try await store.snapshot(for: token)
                        guard !Task.isCancelled, let self, self.names[token] != nil else { return }
                        self.present(snapshot, token: token, filename: filename, pointer: pointer)
                        self.loads[token] = nil
                    } catch {
                        guard let self else { return }
                        self.loads[token] = nil
                        if self.names.removeValue(forKey: token) != nil {
                            self.identities.removeValue(forKey: token)
                            let message = "Screenshot unavailable. Open Recents to check the saved file."
                            self.status = message
                            self.onFeedback?(identity, .failed(message))
                        }
                        await store.close(token)
                    }
                }
            }
        } catch {
            guard generation == closeAllGeneration else { onFeedback?(identity, .closed); return }
            let message = "Screenshot unavailable. Open Recents to check the saved file."
            status = message
            onFeedback?(identity, .failed(message))
        }
    }

    func managePins() { onManagePins?() }
    func openRecents() { onOpenRecents?() }
    func show(_ token: UUID) {
        guard let panel = panels[token] else { return }
        refreshGeometry(panel)
        PinPanelPresentation.present(panel, intent: .explicitShow)
    }
    func close(_ token: UUID) {
        if let identity = identities.removeValue(forKey: token) { onFeedback?(identity, .closed) }
        names.removeValue(forKey: token)
        actionTasks.removeValue(forKey: token)?.cancel()
        actionGeneration.removeValue(forKey: token)
        loads.removeValue(forKey: token)?.cancel()
        if let panel = panels.removeValue(forKey: token) {
            panel.delegate = nil
            panel.close()
            panel.contentViewController = nil
        }
        Task { await store.close(token) }
    }
    func closeAll() {
        closeAllGeneration &+= 1
        for token in Array(names.keys) { close(token) }
    }
    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow,
              let token = panels.first(where: { $0.value === panel })?.key else { return }
        close(token)
    }
    func windowDidChangeBackingProperties(_ notification: Notification) { refreshGeometry(notification) }
    func windowDidChangeScreen(_ notification: Notification) { refreshGeometry(notification) }
    func windowDidMove(_ notification: Notification) { refreshGeometry(notification) }
    func windowDidResize(_ notification: Notification) { refreshGeometry(notification) }

    private func refreshGeometry(_ notification: Notification) {
        guard let panel = notification.object as? PinReferencePanel else { return }
        refreshGeometry(panel)
    }

    private func present(_ snapshot: PinScreenshotSnapshot, token: UUID, filename: String, pointer: CGPoint) {
        let pixels = snapshot.image
        guard let provider = CGDataProvider(data: pixels.rgba as CFData),
              let cgImage = CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: pixels.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else {
            let message = "The pinned preview could not be displayed."
            close(token)
            status = message
            onFeedback?(snapshot.identity, .failed(message))
            return
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: pixels.width, height: pixels.height))
        let panel = PinReferencePanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 340),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Pinned — \(filename)"
        panel.setAccessibilityLabel("Pinned screenshot, \(filename)")
        panel.setAccessibilityValue(filename)
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [] // One Space. No unvalidated all-Spaces/fullscreen eligibility flags.
        panel.animationBehavior = .none
        panel.minSize = CGSize(width: 200, height: 150)
        panel.maxSize = CGSize(width: screen.visibleFrame.width * 0.7, height: screen.visibleFrame.height * 0.7)
        let content = PinPanelContent(image: image, filename: filename,
            width: snapshot.sourceWidth, height: snapshot.sourceHeight, reduced: snapshot.isReduced)
        content.actionsEnabled = actionDriver != nil
        content.onCopyImage = { [weak self] in self?.perform(.copyImage, snapshot: snapshot, token: token) }
        content.onCopyFile = { [weak self] in self?.perform(.copyFile, snapshot: snapshot, token: token) }
        content.onOpen = { [weak self] in self?.perform(.open, snapshot: snapshot, token: token) }
        content.onReveal = { [weak self] in self?.perform(.reveal, snapshot: snapshot, token: token) }
        content.onOpenRecents = { [weak self] in self?.openRecents() }
        panel.contentViewController = content
        panel.delegate = self
        panel.setFrame(PinPanelGeometry.placement(size: panel.frame.size, visible: screen.visibleFrame,
            occupied: panels.values.map(\.frame)), display: false)
        panels[token] = panel
        status = nil
        onFeedback?(snapshot.identity, .shown)
        PinPanelPresentation.present(panel, intent: .passiveLoad)
    }

    private func perform(_ action: PinScreenshotAction, snapshot: PinScreenshotSnapshot, token: UUID) {
        guard panels[token] != nil, let actionDriver else { return }
        actionTasks.removeValue(forKey: token)?.cancel()
        let generation = UUID()
        actionGeneration[token] = generation
        actionTasks[token] = Task { [weak self, actionDriver] in
            let result = await actionDriver(snapshot, action)
            guard !Task.isCancelled, let self, self.actionGeneration[token] == generation,
                  let content = self.panels[token]?.contentViewController as? PinPanelContent else { return }
            self.actionTasks[token] = nil
            content.setActionStatus(result.status, fileActionsAvailable: result.fileActionsAvailable)
            self.status = result.status
        }
    }

    @objc private func displaysChanged() {
        for panel in panels.values { refreshGeometry(panel) }
    }
    private func refreshGeometry(_ panel: PinReferencePanel) {
        guard !adjustingGeometry else { return }
        let screens = NSScreen.screens
        guard let recovery = PinPanelGeometry.recovery(frame: panel.frame,
            visibleFrames: screens.map(\.visibleFrame), currentVisibleFrame: panel.screen?.visibleFrame) else { return }
        adjustingGeometry = true
        defer { adjustingGeometry = false }
        // Update the cap even when preserving an already reachable user position.
        panel.maxSize = recovery.maximumSize
        if panel.frame != recovery.frame { panel.setFrame(recovery.frame, display: true) }
        (panel.contentViewController as? PinPanelContent)?.updateImageSize()
    }
}
