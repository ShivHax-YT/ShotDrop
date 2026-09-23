import AppKit

@MainActor
final class PinManagerWindow: NSObject {
    private var window: NSWindow?
    private var items: [PinScreenshotCoordinator.Item] = []
    var onShow: (UUID) -> Void = { _ in }
    var onClose: (UUID) -> Void = { _ in }
    var onCloseAll: () -> Void = {}

    func update(_ items: [PinScreenshotCoordinator.Item]) {
        self.items = items
        if window != nil { rebuild() }
    }
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Pinned Screenshots"
            window.minSize = NSSize(width: 360, height: 240)
            window.isReleasedWhenClosed = false
            self.window = window
            window.center()
        }
        rebuild(); window?.makeKeyAndOrderFront(nil)
    }
    private func rebuild() {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: items.isEmpty ? "No pinned screenshots." : "Pins remain until you close them. Files are kept."))
        for item in items {
            let label = NSTextField(wrappingLabelWithString: item.filename)
            let show = NSButton(title: "Show", target: self, action: #selector(showPin(_:)))
            let close = NSButton(title: "Close", target: self, action: #selector(closePin(_:)))
            for button in [show, close] {
                button.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
                button.setAccessibilityLabel("\(button.title) pin, \(item.filename)")
            }
            let row = NSStackView(views: [label, show, close]); row.spacing = 8
            stack.addArrangedSubview(row)
        }
        let closeAll = NSButton(title: "Close All Pins", target: self, action: #selector(closeAllPins))
        closeAll.isEnabled = !items.isEmpty
        stack.addArrangedSubview(closeAll)
        window?.contentView = stack
    }
    @objc private func showPin(_ sender: NSButton) {
        if let value = sender.identifier?.rawValue, let id = UUID(uuidString: value) { onShow(id) }
    }
    @objc private func closePin(_ sender: NSButton) {
        if let value = sender.identifier?.rawValue, let id = UUID(uuidString: value) { onClose(id) }
    }
    @objc private func closeAllPins() { onCloseAll() }
}
