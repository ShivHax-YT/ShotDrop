import AppKit
import SwiftUI

enum RecentMenuAction: Sendable {
    case open, copyPreferred, copyImage, copyFile, revealSaved, revealOriginal, retryFileCheck, removeFromRecents
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 64
    @ScaledMetric(relativeTo: .body) private var filenameSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption) private var detailSize: CGFloat = 11
    @State private var availableHeight: CGFloat = 560
    @State private var hoveredID: UUID?
    @State private var clearRequested = false
    @State private var pendingRemoval: UUID?
    @FocusState private var focusedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: 52)
            Divider()
            Text("Recent Screenshots")
                .font(.headline)
                .padding(.horizontal, 16)
                .frame(height: 32, alignment: .leading)

            if rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows.prefix(20)) { row in
                            rowView(row)
                            if row.id != rows.prefix(20).last?.id { Divider().padding(.leading, 80) }
                        }
                    }
                }
                .accessibilityIdentifier("recent.list")
            }

            Divider()
            footer
                .frame(height: 44)
        }
        .frame(width: 352, height: min(560, max(0, availableHeight - 32)))
        .background(.regularMaterial)
        .background(RecentPanelWindowReader { window in
            availableHeight = window.screen?.visibleFrame.height
                ?? NSScreen.main?.visibleFrame.height ?? 592
        }.frame(width: 0, height: 0))
        .onAppear { availableHeight = NSScreen.main?.visibleFrame.height ?? 592 }
        .onAppear { onPanelVisible(true) }
        .onDisappear { onPanelVisible(false) }
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
                    .lineLimit(1).truncationMode(.middle)
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
                : "Take a screenshot with Shift–Command–3 or Shift–Command–4. Recent screenshots will appear here after setup is complete.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Finish Setup…", action: onFinishSetup)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(.horizontal, 24)
        .accessibilityIdentifier("recent.empty")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !rows.isEmpty {
                Button("Clear History") { clearRequested = true }
                    .help("Remove recent entries. Screenshot files remain in their folders.")
            }
            Spacer(minLength: 4)
            Button("Settings…", action: onOpenSettings)
                .keyboardShortcut(",")
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
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
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(row.availability != .saved)
            .focused($focusedID, equals: row.id)
            .accessibilityLabel("Open Screenshot, \(row.displayName)")
            .accessibilityValue(accessibilityValue(row))
            .accessibilityIdentifier("recent.open.\(row.id.uuidString)")

            Button { onAction(row.id, .copyPreferred) } label: {
                Image(systemName: row.copyConfirmation == nil ? "doc.on.doc" : "checkmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(row.availability != .saved)
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
            .help("More actions for \(row.displayName)")
        }
        .frame(minHeight: rowHeight)
        .padding(.horizontal, 16)
        .onHover { hoveredID = $0 ? row.id : nil }
        .onAppear { onRowVisible(row.id, true) }
        .onDisappear { onRowVisible(row.id, false) }
        .contextMenu { actionItems(row) }
        .help("\(row.displayName)\n\(row.savedPath ?? row.sourcePath ?? "No file path")\n\(row.detectedAt.formatted(date: .complete, time: .complete))")
    }

    @ViewBuilder
    private func actionItems(_ row: RecentMenuRow) -> some View {
        Button("Open Screenshot") { onAction(row.id, .open) }
            .disabled(row.availability != .saved)
        Button("Copy Image") { onAction(row.id, .copyImage) }
            .disabled(row.availability != .saved)
        Button("Copy File") { onAction(row.id, .copyFile) }
            .disabled(row.availability != .saved)
        Button("Reveal in Finder") { onAction(row.id, .revealSaved) }
            .disabled(row.availability != .saved)
        if row.availability == .sourceOnly {
            Button("Reveal Original") { onAction(row.id, .revealOriginal) }
        }
        if row.availability == .unavailable {
            Button("Retry File Check") { onAction(row.id, .retryFileCheck) }
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
        "Detected \(row.detectedAt.formatted(date: .complete, time: .complete)). \(row.detail). \(row.savedPath ?? row.sourcePath ?? "File unavailable")"
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

private struct RecentPanelWindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> RecentPanelTrackingView {
        RecentPanelTrackingView(onWindow: onWindow)
    }

    func updateNSView(_ nsView: RecentPanelTrackingView, context: Context) {}
}

@MainActor
private final class RecentPanelTrackingView: NSView {
    let onWindow: @MainActor (NSWindow) -> Void

    init(onWindow: @escaping @MainActor (NSWindow) -> Void) {
        self.onWindow = onWindow
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow(window) }
    }
}
