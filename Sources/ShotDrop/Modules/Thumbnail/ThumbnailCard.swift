import AppKit
import SwiftUI

@MainActor
struct ThumbnailCard: View {
    let capture: ThumbnailCapture
    let image: NSImage
    let feedback: ThumbnailFeedback
    let textSession: ThumbnailTextCopySession?
    let copyImageTitle: String
    let fidelity: String
    let actionsEnabled: Bool
    let validateDrag: @MainActor () async throws -> URL
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onCopyFile: () -> Void
    let onReveal: () -> Void
    let onDismiss: () -> Void
    let onOpenRecents: () -> Void
    let onHover: (Bool) -> Void
    let onFocus: (Bool) -> Void
    let onMenu: (Bool) -> Void
    let onDrag: (Bool) -> Void
    let onSwipe: () -> Void

    @FocusState private var focused: Bool
    @State private var hovering = false
    @State private var swipeOffset: CGFloat = 0

    private var available: Bool { actionsEnabled && feedback.fileActionsAvailable }
    private var hasKeyboardFocus: Bool { focused && feedback.isKeyWindow }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)

            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 240, maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)

            ThumbnailDragSurface(capture: capture, image: image, validateDrag: validateDrag,
                onOpen: openOrRecover, onDrag: onDrag,
                onMenu: onMenu,
                onSwipeChange: { swipeOffset = $0 },
                onSwipeEnd: { dismiss in
                    if dismiss { onSwipe() }
                    else {
                        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                                      ? nil : .spring(response: 0.28, dampingFraction: 0.84)) {
                            swipeOffset = 0
                        }
                    }
                },
                menuFactory: makeMenu)
                .padding(8)

            if let message = feedback.status ?? textSession?.state?.message ?? (fidelity.isEmpty ? nil : fidelity) {
                VStack { Spacer(); Text(message).font(.caption).padding(4).background(.regularMaterial) }
                    .allowsHitTesting(false)
            }

            if hovering || hasKeyboardFocus {
                HStack(spacing: 2) {
                    Menu {
                        if available {
                            Button("Open Screenshot", action: onOpen)
                            Button("Copy File", action: onCopyFile)
                            Button("Reveal in Finder", action: onReveal)
                        } else {
                            Button("Open Recents", action: onOpenRecents)
                        }
                        if actionsEnabled { Button(copyImageTitle, action: onCopy) }
                        if let textSession {
                            if textSession.isRunning {
                                Button("Cancel Copy Text", action: textSession.cancel)
                            } else {
                                Button(textSession.actionTitle) { textSession.start() }
                                    .disabled(!textSession.canStart)
                            }
                        }
                        Divider()
                        Button("Dismiss Thumbnail", action: onDismiss)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .help("Screenshot actions")
                    .accessibilityLabel("Screenshot actions")

                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss Thumbnail")
                    .accessibilityLabel("Dismiss Thumbnail")
                }
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(5)
            }
        }
        .offset(x: swipeOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focused($focused)
        .onKeyPress(keys: [.return, .space], phases: .down) { _ in
            guard hasKeyboardFocus else { return .ignored }
            openOrRecover()
            return .handled
        }
        .overlay {
            if hasKeyboardFocus {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: focused) { _, value in onFocus(value) }
        .onHover { value in hovering = value; onHover(value) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screenshot: \(capture.finalURL.lastPathComponent)")
        .accessibilityValue(fidelity.isEmpty ? "Saved screenshot snapshot" : fidelity)
        .accessibilityActions {
            if available {
                Button("Open Screenshot", action: onOpen)
                Button("Copy File", action: onCopyFile)
                Button("Reveal in Finder", action: onReveal)
            } else {
                Button("Open Recents", action: onOpenRecents)
            }
            if actionsEnabled { Button(copyImageTitle, action: onCopy) }
            if let textSession {
                if textSession.isRunning {
                    Button("Cancel Copy Text", action: textSession.cancel)
                } else {
                    Button(ScreenshotTextCopyState.accessibilityActionTitle(for: textSession.state,
                        filename: capture.finalURL.lastPathComponent)) { textSession.start() }
                        .disabled(!textSession.canStart)
                }
            }
        }
        .accessibilityAction(named: "Dismiss Thumbnail", onDismiss)
    }

    private func openOrRecover() {
        if available { onOpen() } else { onOpenRecents() }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let exists = available
        if exists {
            add("Open Screenshot", to: menu, action: onOpen)
            add("Copy File", to: menu, action: onCopyFile)
            add("Reveal in Finder", to: menu, action: onReveal)
        } else {
            add("Open Recents", to: menu, action: onOpenRecents)
        }
        if actionsEnabled { add(copyImageTitle, to: menu, action: onCopy) }
        if let textSession {
            if textSession.isRunning { add("Cancel Copy Text", to: menu, action: textSession.cancel) }
            else {
                add(textSession.actionTitle, to: menu) { textSession.start() }
                menu.items.last?.isEnabled = textSession.canStart
            }
        }
        menu.addItem(.separator())
        add("Dismiss Thumbnail", to: menu, action: onDismiss)
        return menu
    }

    private func add(_ title: String, to menu: NSMenu, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.invoke), keyEquivalent: "")
        let target = MenuActionTarget(action: action)
        item.target = target
        item.representedObject = target // NSMenuItem.target is weak.
        menu.addItem(item)
    }
}

private final class MenuActionTarget: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}

@MainActor
private struct ThumbnailDragSurface: NSViewRepresentable {
    let capture: ThumbnailCapture
    let image: NSImage
    let validateDrag: @MainActor () async throws -> URL
    let onOpen: () -> Void
    let onDrag: (Bool) -> Void
    let onMenu: (Bool) -> Void
    let onSwipeChange: (CGFloat) -> Void
    let onSwipeEnd: (Bool) -> Void
    let menuFactory: () -> NSMenu

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.capture = capture
        view.image = image
        view.validateDrag = validateDrag
        view.onOpen = onOpen
        view.onDrag = onDrag
        view.onMenu = onMenu
        view.onSwipeChange = onSwipeChange
        view.onSwipeEnd = onSwipeEnd
        view.menuFactory = menuFactory
    }
}

@MainActor
private final class DragSourceView: NSView, NSDraggingSource, NSMenuDelegate {
    var capture: ThumbnailCapture?
    var image: NSImage?
    var validateDrag: (@MainActor () async throws -> URL)?
    private var dragTask: Task<Void, Never>?
    private var gestureID = UUID()
    var onOpen: (() -> Void)?
    var onDrag: ((Bool) -> Void)?
    var onMenu: ((Bool) -> Void)?
    var onSwipeChange: ((CGFloat) -> Void)?
    var onSwipeEnd: ((Bool) -> Void)?
    var menuFactory: (() -> NSMenu)?
    private var mouseDownEvent: NSEvent?
    private var beganDrag = false
    private var swipeDistance: CGFloat = 0
    private var swipeVelocity: CGFloat = 0
    private var lastScrollTime: TimeInterval = 0
    private var horizontalIntent = false

    override func mouseDown(with event: NSEvent) {
        gestureID = UUID()
        mouseDownEvent = event
        beganDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !beganDrag, dragTask == nil, let down = mouseDownEvent,
              let image, let validateDrag else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) >= ThumbnailPolicy.dragThreshold else { return }
        beganDrag = true
        let gesture = gestureID
        onDrag?(true)
        dragTask = Task { [weak self] in
            do {
                let url = try await validateDrag()
                guard let self else { return }
                self.dragTask = nil
                guard self.gestureID == gesture, self.window?.isVisible == true,
                      NSEvent.pressedMouseButtons & 1 != 0 else { self.onDrag?(false); return }
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                item.setDraggingFrame(self.bounds, contents: image)
                self.beginDraggingSession(with: [item], event: down, source: self)
            } catch {
                self?.dragTask = nil
                self?.onDrag?(false)
                self?.setAccessibilityHelp("Saved file unavailable or changed. Open Recents to recover it.")
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownEvent = nil; beganDrag = false; gestureID = UUID()
            if dragTask != nil { dragTask?.cancel() }
        }
        guard !beganDrag, let down = mouseDownEvent else { return }
        let distance = hypot(event.locationInWindow.x - down.locationInWindow.x,
                             event.locationInWindow.y - down.locationInWindow.y)
        if distance < ThumbnailPolicy.dragThreshold { onOpen?() }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDrag?(false)
        mouseDownEvent = nil
        beganDrag = true // A canceled drag cannot become a click.
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = menuFactory?()
        menu?.delegate = self
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) { onMenu?(true) }
    func menuDidClose(_ menu: NSMenu) { onMenu?(false) }

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.phase != [] else {
            super.scrollWheel(with: event)
            return
        }
        if event.phase.contains(.began) {
            swipeDistance = 0; swipeVelocity = 0; horizontalIntent = false
        }
        let trailingDelta = -event.scrollingDeltaX
        swipeDistance += trailingDelta
        let elapsed = max(0.001, event.timestamp - lastScrollTime)
        swipeVelocity = trailingDelta / elapsed
        lastScrollTime = event.timestamp
        if abs(swipeDistance) >= 10 && abs(swipeDistance) > abs(event.scrollingDeltaY) {
            horizontalIntent = true
        }
        if horizontalIntent { onSwipeChange?(max(0, swipeDistance)) }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            onSwipeEnd?(horizontalIntent && ThumbnailPolicy.shouldDismissSwipe(
                translation: CGSize(width: swipeDistance, height: event.scrollingDeltaY),
                velocity: CGSize(width: swipeVelocity, height: 0)))
            swipeDistance = 0; horizontalIntent = false
        }
    }
}
