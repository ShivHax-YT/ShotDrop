import AppKit

@MainActor
final class PinManagerWindow: NSObject {
    private enum FocusTarget: Hashable {
        case show(UUID), close(UUID), closeAll
        var pinID: UUID? {
            switch self { case .show(let id), .close(let id): id; case .closeAll: nil }
        }
    }
    private var window: NSWindow?
    private var items: [PinScreenshotCoordinator.Item] = []
    private var buttons: [FocusTarget: NSButton] = [:]
    var onShow: (UUID) -> Void = { _ in }
    var onClose: (UUID) -> Void = { _ in }
    var onCloseAll: () -> Void = {}

    func update(_ items: [PinScreenshotCoordinator.Item]) {
        guard self.items.count != items.count || !zip(self.items, items).allSatisfy({
            $0.id == $1.id && $0.filename == $1.filename
        }) else { return }
        let focused = buttons.first { $0.value === window?.firstResponder }?.key
        let oldIndex = focused?.pinID.flatMap { id in self.items.firstIndex { $0.id == id } } ?? 0
        self.items = items
        guard window != nil else { return }
        rebuild()
        if let focused {
            let fallback = items.isEmpty ? nil : buttons[.show(items[min(oldIndex, items.count - 1)].id)]
            let replacement = buttons[focused].flatMap { $0.isEnabled ? $0 : nil } ?? fallback
            if let replacement {
                window?.makeFirstResponder(replacement)
                replacement.scrollToVisible(replacement.bounds)
            } else { window?.makeFirstResponder(window) }
        }
    }

    func show() { prepareWindow().makeKeyAndOrderFront(nil) }

    /// Builds the window without ordering or activating it; also supports hidden layout tests.
    @discardableResult
    func prepareWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Pinned Screenshots"
        window.minSize = NSSize(width: 360, height: 240)
        window.isReleasedWhenClosed = false
        self.window = window
        window.center()
        rebuild()
        return window
    }

    private func rebuild() {
        buttons.removeAll()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.setAccessibilityLabel("Pinned screenshots")
        let stack = PinManagerDocumentStack()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let description = NSTextField(wrappingLabelWithString: items.isEmpty ? "No pinned screenshots." : "Pins remain until you close them. Files are kept.")
        stack.addArrangedSubview(description)
        description.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        for item in items {
            let label = NSTextField(wrappingLabelWithString: item.filename)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let show = NSButton(title: "Show", target: self, action: #selector(showPin(_:)))
            let close = NSButton(title: "Close", target: self, action: #selector(closePin(_:)))
            buttons[.show(item.id)] = show; buttons[.close(item.id)] = close
            for button in [show, close] {
                button.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
                button.setAccessibilityLabel("\(button.title) pin, \(item.filename)")
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
                button.setContentHuggingPriority(.required, for: .horizontal)
            }
            let row = NSStackView(views: [label, show, close]); row.spacing = 8; row.alignment = .top
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        let closeAll = NSButton(title: "Close All Pins", target: self, action: #selector(closeAllPins))
        closeAll.isEnabled = !items.isEmpty
        buttons[.closeAll] = closeAll
        stack.addArrangedSubview(closeAll)
        scroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        window?.contentView = scroll
    }
    @objc private func showPin(_ sender: NSButton) {
        if let value = sender.identifier?.rawValue, let id = UUID(uuidString: value) { onShow(id) }
    }
    @objc private func closePin(_ sender: NSButton) {
        if let value = sender.identifier?.rawValue, let id = UUID(uuidString: value) { onClose(id) }
    }
    @objc private func closeAllPins() { onCloseAll() }
}

/// AppKit scroll documents begin at their top-left even when their content exceeds the viewport.
@MainActor
private final class PinManagerDocumentStack: NSStackView {
    override var isFlipped: Bool { true }
}
