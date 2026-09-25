import AppKit
import SwiftUI

enum RecentMenuAction: Sendable {
    case retrySave, trashSaved, open, copyPreferred, copyImage, copyFile, copyText, cancelCopyText, annotate, pin, revealSaved, revealOriginal, retryFileCheck, removeFromRecents
}

struct RecentMenuRow: Identifiable, Sendable {
    enum Availability: Sendable, Equatable {
        case saved, sourceOnly, missing, unavailable, checking
    }

    let id: UUID
    let displayName: String
    let detectedAt: Date
    let detail: String
    let availability: Availability
    let savedPath: String?
    let sourcePath: String?
    let previewImage: RecentPreviewImage?
    let copyConfirmation: CopyMode?

    func allows(_ action: RecentMenuAction) -> Bool {
        switch action {
        case .trashSaved, .open, .copyPreferred, .copyImage, .copyFile, .copyText, .annotate, .pin, .revealSaved:
            availability == .saved
        case .retrySave, .revealOriginal: availability == .sourceOnly
        case .retryFileCheck: availability == .unavailable || availability == .saved
        case .removeFromRecents: availability == .missing
        case .cancelCopyText: true
        }
    }
}

/// View-only panel. The controller validates a row and its file again for every action.
@MainActor
struct RecentMenuPanel: View {
    let rows: [RecentMenuRow]
    let status: String
    let historyUnavailable: Bool
    let preferredCopyMode: CopyMode
    let onAction: (UUID, RecentMenuAction) -> Void
    let onClearHistory: () -> Void
    let onFinishSetup: () -> Void
    let onOpenSettings: () -> Void
    let onPanelVisible: (Bool) -> Void
    let onRowVisible: (UUID, Bool) -> Void
    var textCopyStates: [UUID: ScreenshotTextCopyState] = [:]
    var isRecognizingText = false
    var setupTitle = "Finish Setup…"
    var pinCount = 0
    var onManagePins: () -> Void = {}
    var pinFeedback: [UUID: String] = [:]
    var annotationFeedback: [UUID: String] = [:]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 64
    @ScaledMetric(relativeTo: .body) private var filenameSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var detailSize: CGFloat = 11
    @State private var availableHeight: CGFloat = 560
    @State private var measuredHeights: [String: CGFloat] = [:]
    @State private var hoveredID: UUID?
    @State private var clearRequested = false
    @State private var pendingTrash: UUID?
    @State private var pendingRemoval: UUID?
    @State private var panelWindowReference = RecentPanelWindowReference()
    @FocusState private var focusedID: UUID?

    private var layout: RecentMenuLayout {
        let totalRows = rows.prefix(20).reduce(CGFloat(0)) {
            $0 + max(rowHeight, measuredHeights[$1.id.uuidString] ?? rowHeight)
        } + CGFloat(max(0, min(rows.count, 20) - 1))
        return RecentMenuLayout.measure(rowCount: rows.count,
            chromeHeight: (measuredHeights["header"] ?? 52) + 32 + (measuredHeights["footer"] ?? 92) + 2,
            emptyHeight: measuredHeights["empty"] ?? 160, estimatedRowHeight: rowHeight,
            measuredTotalRowHeight: totalRows, availableHeight: availableHeight)
    }
    private var contentAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: RecentMenuLayout.transitionDuration(reduceMotion: false))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 52)
                .background(heightReader("header"))
            Divider()
            Text("Recent Screenshots")
                .font(.headline)
                .padding(.horizontal, 16)
                .frame(height: 32, alignment: .leading)

            if rows.isEmpty {
                ScrollView {
                    emptyState
                        .fixedSize(horizontal: false, vertical: true)
                        .background(heightReader("empty"))
                }
                .frame(height: layout.bodyHeight)
                .transition(.opacity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows.prefix(20)) { row in
                            rowView(row)
                                .background(heightReader(row.id.uuidString))
                            if row.id != rows.prefix(20).last?.id { Divider().padding(.leading, 80) }
                        }
                    }
                }
                .accessibilityIdentifier("recent.list")
                .frame(height: layout.bodyHeight)
                .transition(.opacity)
            }

            Divider()
            footer
                .frame(minHeight: 72)
                .fixedSize(horizontal: false, vertical: true)
                .background(heightReader("footer"))
        }
        .frame(width: 352)
        .fixedSize(horizontal: false, vertical: true)
        .animation(contentAnimation, value: rows.isEmpty)
        .animation(contentAnimation, value: historyUnavailable)
        .animation(contentAnimation, value: layout.panelHeight)
        .background(.regularMaterial)
        .background(RecentPanelWindowReader(contentSize: CGSize(width: 352, height: layout.panelHeight + 40)) { window in
            panelWindowReference.window = window
            availableHeight = window.screen?.visibleFrame.height
                ?? NSScreen.main?.visibleFrame.height ?? 592
        }.frame(width: 0, height: 0))
        .onPreferenceChange(RecentPanelHeightKey.self) { heights in
            let keys = Set(rows.prefix(20).map { $0.id.uuidString } + ["header", "footer", "empty"])
            var next = measuredHeights.filter { keys.contains($0.key) }
            for (key, height) in heights where keys.contains(key) && height.isFinite && height > 0 { next[key] = height }
            if next != measuredHeights { measuredHeights = next }
        }
        .onAppear {
            availableHeight = panelWindowReference.window?.screen?.visibleFrame.height
                ?? NSScreen.main?.visibleFrame.height ?? 592
        }
        .onAppear { onPanelVisible(true) }
        .onDisappear { onPanelVisible(false) }
        .onChange(of: textCopyStates) { old, new in
            guard let panelWindow = panelWindowReference.window else { return }
            for row in rows {
                guard let state = new[row.id], state != old[row.id], state != .copying else { continue }
                NSAccessibility.post(element: panelWindow, notification: .announcementRequested,
                                     userInfo: [.announcement: "\(row.displayName): \(state.message)",
                                                .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
        .onChange(of: annotationFeedback) { old, new in
            guard let window = panelWindowReference.window else { return }
            for row in rows {
                guard let feedback = new[row.id], old[row.id] != feedback else { continue }
                NSAccessibility.post(element: window, notification: .announcementRequested,
                                     userInfo: [.announcement: "\(row.displayName): \(feedback)",
                                                .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
        .onChange(of: pinFeedback) { old, new in
            guard let window = panelWindowReference.window else { return }
            for row in rows {
                guard let feedback = new[row.id], old[row.id] != feedback else { continue }
                NSAccessibility.post(element: window, notification: .announcementRequested,
                                     userInfo: [.announcement: "\(row.displayName): \(feedback)",
                                                .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        }
        .confirmationDialog("Move saved copy to Trash? The original screenshot stays in place.",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })) {
            Button("Move to Trash", role: .destructive) { if let id = pendingTrash { onAction(id, .trashSaved) }; pendingTrash = nil }
            Button("Cancel", role: .cancel) { pendingTrash = nil }
        }
        .confirmationDialog("Clear recent history? Screenshot files will stay in their folders.",
                            isPresented: $clearRequested) {
            Button("Clear History", role: .destructive, action: onClearHistory)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove this entry from Recents? The screenshot file will not be deleted.",
                            isPresented: Binding(
                                get: { pendingRemoval != nil },
                                set: { if !$0 { pendingRemoval = nil } }
                            )) {
            Button("Remove from Recents", role: .destructive) {
                if let pendingRemoval { onAction(pendingRemoval, .removeFromRecents) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        }
        .background {
            if let focusedID {
                Button("Copy focused screenshot") { onAction(focusedID, .copyPreferred) }
                    .keyboardShortcut("c", modifiers: [.command])
                    .hidden()
                Button("Copy focused screenshot file") { onAction(focusedID, .copyFile) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .hidden()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("ShotDrop").font(.headline)
                Text(status).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(historyUnavailable ? "Recent history unavailable" : "No screenshots yet")
                .font(.headline)
            Text(historyUnavailable
                ? "ShotDrop kept the unreadable history file. Your screenshot files were not changed."
                : "Take a screenshot with Shift–Command–3 or Shift–Command–4. New screenshots appear here after setup. Your originals stay in place.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(.horizontal, 24)
        .accessibilityIdentifier("recent.empty")
    }

    private func heightReader(_ key: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: RecentPanelHeightKey.self, value: [key: proxy.size.height])
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack {
                Button(setupTitle, action: onFinishSetup)
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("recent.finishSetup")
                    .help("Resume ShotDrop setup")
                Spacer(minLength: 4)
                Button("Pins (\(pinCount))", action: onManagePins)
                    .help("Show or close pinned screenshots")
            }
            HStack {
                Button("Settings…", action: onOpenSettings)
                    .keyboardShortcut(",")
                Spacer(minLength: 4)
                if !rows.isEmpty {
                    Button("Clear History") { clearRequested = true }
                        .help("Remove recent entries. Screenshot files remain in their folders.")
                    Spacer(minLength: 4)
                }
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityIdentifier("recent.footer")
    }

    private func rowView(_ row: RecentMenuRow) -> some View {
        HStack(spacing: 8) {
            Button {
                onAction(row.id, .open)
            } label: {
                HStack(spacing: 8) {
                    preview(row)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.displayName)
                            .font(.system(size: filenameSize, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(row.detectedAt.formatted(date: .abbreviated, time: .shortened)) · \(row.detail)")
                            .font(.system(size: detailSize))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if let feedback = pinFeedback[row.id] {
                            Text(feedback).font(.system(size: detailSize)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let feedback = annotationFeedback[row.id] {
                            Text(feedback)
                                .font(.system(size: detailSize))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("recent.annotationStatus.\(row.id.uuidString)")
                        }
                        if let textState = textCopyStates[row.id] {
                            Text(textState.message)
                                .font(.system(size: detailSize))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("recent.textStatus.\(row.id.uuidString)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!row.allows(.open))
            .focused($focusedID, equals: row.id)
            .accessibilityLabel("Open Screenshot, \(row.displayName)")
            .accessibilityValue(accessibilityValue(row))
            .accessibilityIdentifier("recent.open.\(row.id.uuidString)")

            Button { onAction(row.id, .copyPreferred) } label: {
                Image(systemName: row.copyConfirmation == nil ? "doc.on.doc" : "checkmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!row.allows(.copyPreferred))
            .accessibilityLabel(row.copyConfirmation.map { "Copied \($0.title.lowercased()) for \(row.displayName)" }
                ?? "Copy \(preferredCopyMode.title.lowercased()) for \(row.displayName)")
            .help("Copy \(preferredCopyMode.title.lowercased()) for \(row.displayName)")

            Menu {
                actionItems(row)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .opacity(hoveredID == row.id || focusedID == row.id ? 1 : 0.35)
            .accessibilityLabel("More actions for \(row.displayName)")
            .accessibilityValue(row.detail)
            .help("More actions for \(row.displayName)")
        }
        .frame(minHeight: rowHeight)
        .padding(.horizontal, 16)
        .onHover { hoveredID = $0 ? row.id : nil }
        .onAppear { onRowVisible(row.id, true) }
        .onDisappear { onRowVisible(row.id, false) }
        .contextMenu { actionItems(row) }
        .accessibilityActions {
            if row.allows(.pin) {
                Button("Pin Screenshot, \(row.displayName)") { onAction(row.id, .pin) }
            }
            if row.allows(.annotate) {
                Button("Annotate \(row.displayName)") { onAction(row.id, .annotate) }
            }
            if row.allows(.copyText) && !isRecognizingText && textCopyStates[row.id] != .unavailable {
                Button(ScreenshotTextCopyState.accessibilityActionTitle(for: textCopyStates[row.id], filename: row.displayName)) {
                    onAction(row.id, .copyText)
                }
            }
            if textCopyStates[row.id] == .recognizing {
                Button("Cancel Text Recognition for \(row.displayName)") { onAction(row.id, .cancelCopyText) }
            }
        }
        .help("\(row.displayName)\n\(row.savedPath ?? row.sourcePath ?? "No file path")\n\(row.detectedAt.formatted(date: .complete, time: .complete))")
    }

    @ViewBuilder
    private func actionItems(_ row: RecentMenuRow) -> some View {
        Button("Open Screenshot") { onAction(row.id, .open) }
            .disabled(!row.allows(.open))
        Button("Copy Image") { onAction(row.id, .copyImage) }
            .disabled(!row.allows(.copyImage))
        Button("Pin Screenshot") { onAction(row.id, .pin) }
            .disabled(!row.allows(.pin))
            .accessibilityLabel("Pin Screenshot, \(row.displayName)")
        Button("Annotate…") { onAction(row.id, .annotate) }
            .disabled(!row.allows(.annotate))
            .accessibilityLabel("Annotate \(row.displayName)")
        Button("Copy File") { onAction(row.id, .copyFile) }
            .disabled(!row.allows(.copyFile))
        Button(ScreenshotTextCopyState.actionTitle(for: textCopyStates[row.id])) { onAction(row.id, .copyText) }
            .disabled(!row.allows(.copyText) || isRecognizingText || textCopyStates[row.id] == .unavailable)
            .accessibilityLabel(ScreenshotTextCopyState.accessibilityActionTitle(for: textCopyStates[row.id], filename: row.displayName))
            .help(isRecognizingText ? "One text recognition is already running. Try again when it finishes."
                  : "Recognize text on this Mac from this saved screenshot. The image stays on this Mac. Check the text after pasting; complex layouts may need correction.")
        if textCopyStates[row.id] == .recognizing {
            Button("Cancel Text Recognition") { onAction(row.id, .cancelCopyText) }
                .help("Discard this result. Another recognition can start when the current worker finishes.")
        }
        Button("Move Saved Copy to Trash…", role: .destructive) { pendingTrash = row.id }
            .disabled(!row.allows(.trashSaved))
        Button("Reveal in Finder") { onAction(row.id, .revealSaved) }
            .disabled(!row.allows(.revealSaved))
        if row.allows(.retrySave) {
            Button("Retry Saving") { onAction(row.id, .retrySave) }
        }
        if row.allows(.revealOriginal) {
            Button("Reveal Original") { onAction(row.id, .revealOriginal) }
        }
        if row.availability == .unavailable || textCopyStates[row.id] == .unavailable {
            Button("Retry File Check") { onAction(row.id, .retryFileCheck) }
                .disabled(!row.allows(.retryFileCheck))
        }
        if row.availability == .missing {
            Button("Remove from Recents") { pendingRemoval = row.id }
        }
    }

    private func preview(_ row: RecentMenuRow) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
            if let preview = row.previewImage, let image = makeImage(preview) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: row.availability == .missing || row.availability == .unavailable
                    ? "questionmark.square" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 40)
        .accessibilityHidden(true)
    }

    private func accessibilityValue(_ row: RecentMenuRow) -> String {
        "Detected \(row.detectedAt.formatted(date: .complete, time: .complete)). \(row.detail). \(textCopyStates[row.id]?.message ?? ""). \(annotationFeedback[row.id] ?? ""). \(pinFeedback[row.id] ?? ""). \(row.savedPath ?? row.sourcePath ?? "File unavailable")"
    }

    private func makeImage(_ preview: RecentPreviewImage) -> NSImage? {
        guard preview.width > 0, preview.height > 0,
              preview.bytesPerRow == preview.width * 4,
              preview.rgba.count == preview.bytesPerRow * preview.height,
              let provider = CGDataProvider(data: preview.rgba as CFData),
              let image = CGImage(width: preview.width, height: preview.height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: preview.bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                    | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: preview.width, height: preview.height))
    }
}

@MainActor
private final class RecentPanelWindowReference {
    weak var window: NSWindow?
}

private struct RecentPanelHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Keep the status-item window's top edge anchored when content changes size.
/// Resizing is immediate; only content crossfades, avoiding moving controls.
@MainActor
enum RecentMenuWindowSizing {
    static func apply(_ size: CGSize, to window: NSWindow) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let old = window.frame
        var target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        guard abs(target.width - old.width) > 0.5 || abs(target.height - old.height) > 0.5 else { return }
        target.origin = CGPoint(x: old.minX, y: old.maxY - target.height)
        if let visible = window.screen?.visibleFrame {
            target.origin.x = max(visible.minX, min(target.minX, visible.maxX - target.width))
            target.origin.y = max(visible.minY, min(target.minY, visible.maxY - target.height))
        }
        window.setFrame(target, display: true, animate: false)
    }
}

private struct RecentPanelWindowReader: NSViewRepresentable {
    let contentSize: CGSize
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> RecentPanelTrackingView {
        RecentPanelTrackingView(onWindow: onWindow)
    }

    func updateNSView(_ nsView: RecentPanelTrackingView, context: Context) {
        nsView.requestSize(contentSize)
    }
}

@MainActor
private final class RecentPanelTrackingView: NSView {
    let onWindow: @MainActor (NSWindow) -> Void
    private var requestedSize: CGSize?
    private var resizeTask: Task<Void, Never>?

    init(onWindow: @escaping @MainActor (NSWindow) -> Void) {
        self.onWindow = onWindow
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            onWindow(window)
            if let requestedSize { requestSize(requestedSize) }
        } else { resizeTask?.cancel(); resizeTask = nil }
    }

    func requestSize(_ size: CGSize) {
        requestedSize = size
        resizeTask?.cancel()
        // Coalesce SwiftUI measurement updates outside the current layout pass.
        resizeTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, let window = self.window else { return }
            RecentMenuWindowSizing.apply(size, to: window)
            self.resizeTask = nil
        }
    }
}
