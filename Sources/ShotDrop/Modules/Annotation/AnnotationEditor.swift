import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class AnnotationEditorModel {
    let identity: AnnotationSessionIdentity
    private let renderer: AnnotationRenderer
    private let sourceLoader: (@Sendable (RecentFileReference) async throws -> AnnotationSource)?
    private let previewRenderer: (@Sendable (AnnotationSource, AnnotationState) async throws -> AnnotationRaster)?
    private(set) var rendering = false
    private(set) var previewFailed = false
    private(set) var gestureActive = false
    private var gestureRevision: UInt64?
    private(set) var source: AnnotationSource?
    private(set) var document: AnnotationDocument?
    private(set) var image: CGImage?
    private(set) var renderedCrop: CGRect?
    private(set) var renderedRevision: UInt64?
    private(set) var busy = false
    var message = "Loading verified saved image…"
    var tool: AnnotationTool = .select
    var selected: UUID?
    var cropDraft: CGRect?
    var zoom: Double = 1
    var fit = true
    private var task: Task<Void, Never>?
    private var previewRequested = false
    private var shouldAnnouncePreviewResult = false
    @ObservationIgnored var openRecents: (() -> Void)?
    @ObservationIgnored var announceResult: ((String) -> Void)?
    private var closed = false
    static let exportUnavailable = AnnotationExportAvailability.explanation

    init(identity: AnnotationSessionIdentity, renderer: AnnotationRenderer = AnnotationRenderer(), sourceLoader: (@Sendable (RecentFileReference) async throws -> AnnotationSource)? = nil, previewRenderer: (@Sendable (AnnotationSource, AnnotationState) async throws -> AnnotationRaster)? = nil) { self.identity = identity; self.renderer = renderer; self.sourceLoader = sourceLoader; self.previewRenderer = previewRenderer }
    func load() {
        guard task == nil, source == nil, !closed else { return }
        busy = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let value: AnnotationSource
                if let sourceLoader { value = try await sourceLoader(identity.reference) }
                else { value = try await renderer.load(reference: identity.reference) }
                try Task.checkCancellation()
                guard !closed else { throw CancellationError() }
                source = value
                document = try AnnotationDocument(width: value.width, height: value.height)
                shouldAnnouncePreviewResult = true
                message = "Original unchanged · Preview only. Visual blur is not secure redaction."
            } catch {
                message = "Screenshot unavailable. Restore the saved copy, then retry, or open Recents to check its last saved location."
                if !closed { announceResult?(message + " Retry Image.") }
            }
            busy = false; task = nil
            if source != nil { refresh() }
        }
    }
    var hasPendingWork: Bool { task != nil }
    func finishPendingWork() async { while let pending = task { await pending.value } }
    func close() { closed = true; task?.cancel() }
    func retry() {
        if source != nil, document != nil { shouldAnnouncePreviewResult = true; refresh() } else { load() }
    }
    func chooseZoom(_ value: Double) { zoom = value; fit = false }
    func save() { message = Self.exportUnavailable }
    func beginGesture() { gestureActive = true; gestureRevision = document?.revision }
    func endGesture() { gestureActive = false; gestureRevision = nil }
    func cancelGesture() { endGesture(); cropDraft = nil }
    func commit(_ state: AnnotationState) {
        do { try document?.commit(state); refresh() }
        catch { message = "This edit exceeds the image or annotation limits. The previous edit is preserved." }
    }
    func undo() {
        if gestureActive || cropDraft != nil { cancelGesture(); return }
        document?.undo(); refresh()
    }
    func redo() {
        if gestureActive || cropDraft != nil { cancelGesture(); return }
        document?.redo(); refresh()
    }
    func deleteSelected() {
        guard var state = document?.state, let selected else { return }
        state.marks.removeAll { $0.id == selected }; self.selected = nil; commit(state)
    }
    func changeSelected(_ change: (inout AnnotationMark) -> Void) {
        guard var state = document?.state, let index = state.marks.firstIndex(where: { $0.id == selected }) else { return }
        change(&state.marks[index]); commit(state)
    }
    func moveSelected(dx: CGFloat, dy: CGFloat) {
        guard let document, let mark = document.state.marks.first(where: { $0.id == selected }) else { return }
        let x = min(max(dx, -mark.bounds.minX), CGFloat(document.width) - mark.bounds.maxX)
        let y = min(max(dy, -mark.bounds.minY), CGFloat(document.height) - mark.bounds.maxY)
        changeSelected { value in
            value.start.x += x; value.end.x += x; value.start.y += y; value.end.y += y
        }
    }
    func gesture(start: CGPoint, end: CGPoint) {
        guard var state = document?.state, renderedRevision == document?.revision,
              !gestureActive || gestureRevision == document?.revision else { return }
        if tool == .select {
            if let mark = state.marks.reversed().first(where: { $0.bounds.insetBy(dx: -8, dy: -8).contains(start) }) {
                selected = mark.id; moveSelected(dx: end.x - start.x, dy: end.y - start.y)
            } else { selected = nil }
            return
        }
        let bounds = CGRect(x: min(start.x,end.x), y: min(start.y,end.y), width: abs(end.x-start.x), height: abs(end.y-start.y))
        if tool == .arrow {
            guard hypot(end.x - start.x, end.y - start.y) >= 1 else { return }
        } else {
            guard bounds.width >= 1, bounds.height >= 1 else { return }
        }
        if tool == .crop { cropDraft = bounds.integral.intersection(state.crop); return }
        let mark = AnnotationMark(tool: tool, start: start, end: end)
        state.marks.append(mark); selected = mark.id; commit(state)
    }
    var canRedo: Bool { gestureActive || cropDraft != nil || document?.redoStates.isEmpty == false }
    var canAddSelectedTool: Bool {
        guard !closed, !busy, let document, tool != .select else { return false }
        return tool == .crop || document.state.marks.count < AnnotationDocument.maximumMarks
    }
    /// Keyboard and assistive-technology entry point; geometry remains in upright source pixels.
    func addSelectedTool() {
        guard canAddSelectedTool, var state = document?.state else { return }
        cancelGesture()
        let crop = state.crop
        let width = max(1, min(160, floor(crop.width / 2)))
        let height = max(1, min(100, floor(crop.height / 2)))
        let initial = CGRect(x: floor(crop.midX - width / 2), y: floor(crop.midY - height / 2),
                             width: width, height: height)
        if tool == .crop {
            cropDraft = initial
            announceResult?("Crop preview created. Adjust its source-pixel bounds, then choose Apply Crop or Cancel Crop.")
        } else {
            let mark = AnnotationMark(tool: tool, start: initial.origin,
                                      end: CGPoint(x: initial.maxX, y: initial.maxY))
            state.marks.append(mark)
            commit(state)
            if document?.state.marks.contains(where: { $0.id == mark.id }) == true {
                selected = mark.id
                announceResult?("Added " + mark.tool.rawValue + ". Adjust the selected object's properties.")
            }
        }
    }
    func changeCropDraft(_ change: (inout CGRect) -> Void) {
        guard var next = cropDraft, let document, !closed else { return }
        change(&next)
        let values = [next.origin.x, next.origin.y, next.size.width, next.size.height]
        guard values.allSatisfy({ $0.isFinite }), next.size.width >= 1, next.size.height >= 1,
              next == next.integral, document.state.crop.contains(next) else {
            message = "Crop bounds must use whole source pixels inside the current image. The previous crop preview is preserved."
            return
        }
        cropDraft = next
    }
    func applyCrop() {
        guard let cropDraft, var state = document?.state else { return }
        state.crop = cropDraft; self.cropDraft = nil; commit(state)
    }
    private func refresh() {
        guard !closed, source != nil, document != nil else { return }
        previewRequested = true; previewFailed = false
        guard task == nil else { return }
        rendering = true
        task = Task { [weak self] in
            guard let self else { return }
            // At most one renderer operation exists; rapid edits coalesce to the latest state.
            while previewRequested, !closed {
                previewRequested = false
                guard let source, let document else { break }
                let revision = document.revision
                do {
                    let raster: AnnotationRaster
                    if let previewRenderer { raster = try await previewRenderer(source, document.state) }
                    else { raster = try await renderer.preview(source: source, state: document.state) }
                    try Task.checkCancellation()
                    if self.document?.revision == revision, !closed {
                        image = try AnnotationRenderer.image(raster: raster)
                        renderedCrop = document.state.crop; renderedRevision = revision
                        previewFailed = false
                        message = "Original unchanged · Preview only. Visual blur is not secure redaction."
                    }
                } catch { if !closed { previewFailed = true; message = "Preview unavailable. Your edits are preserved. Retry the preview or undo the edit." } }
            }
            rendering = false; task = nil
            if shouldAnnouncePreviewResult, !closed {
                shouldAnnouncePreviewResult = false
                announceResult?(previewFailed ? message + " Retry Preview." : "Annotation preview ready. " + message)
            }
        }
    }
}

@MainActor
final class AnnotationEditorCoordinator: NSObject, NSWindowDelegate {
    private struct Session {
        let model: AnnotationEditorModel
        let controller: NSWindowController
    }
    private var registry = AnnotationSessionRegistry()
    private var sessions: [UUID: Session] = [:]
    // All admitted windows share one renderer, including uncancellable decoder work.
    private let renderer = AnnotationRenderer()
    private(set) var admissionMessage: String?

    @discardableResult func open(identity: AnnotationSessionIdentity, openRecents: @escaping () -> Void) -> Bool {
        admissionMessage = nil
        let token: UUID
        switch registry.admit(identity) {
        case .existing(let existing):
            sessions[existing]?.controller.showWindow(nil)
            sessions[existing]?.controller.window?.makeKeyAndOrderFront(nil)
            return true
        case .closing:
            admissionMessage = "This annotation is still closing. Try again when it finishes."
            return false
        case .full:
            admissionMessage = "You can edit up to 3 screenshots. Close an annotation window to open another."
            return false
        case .opened(let admitted): token = admitted
        }
        let model = AnnotationEditorModel(identity: identity, renderer: renderer)
        model.openRecents = openRecents
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Annotate — " + URL(fileURLWithPath: identity.reference.lastKnownPath).lastPathComponent
        window.minSize = NSSize(width: 640, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        model.announceResult = { [weak window] message in
            guard let window, window.isVisible else { return }
            NSAccessibility.post(element: window, notification: .announcementRequested,
                                 userInfo: [.announcement: message,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        window.contentView = NSHostingView(rootView: AnnotationEditorView(model: model))
        window.center()
        let controller = NSWindowController(window: window)
        sessions[token] = Session(model: model, controller: controller)
        controller.showWindow(nil); window.makeKeyAndOrderFront(nil); model.load()
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model = sessions.values.first(where: { $0.controller.window === sender })?.model,
              model.document?.isDirty == true else { return true }
        let alert = NSAlert()
        alert.messageText = "Keep your annotation edits?"
        alert.informativeText = AnnotationExportAvailability.dirtyCloseExplanation
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Edits")
        alert.addButton(withTitle: "Save Copy…")
        alert.buttons[2].isEnabled = false
        return alert.runModal() == .alertSecondButtonReturn
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let (token, session) = sessions.first(where: { $0.value.controller.window === window }),
              registry.beginClosing(token: token) else { return }
        session.model.close()
        Task { [self] in
            await session.model.finishPendingWork()
            guard registry.releaseAfterDrain(token: token) else { return }
            sessions.removeValue(forKey: token)
        }
    }
}

@MainActor
private struct AnnotationEditorView: View {
    @Bindable var model: AnnotationEditorModel
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var gestureCancelled = false
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack {
                    Picker("Tool", selection: $model.tool) {
                        ForEach(AnnotationTool.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(minWidth: 510)
                    Button("Undo", action: model.undo).keyboardShortcut("z").disabled(model.document?.undoStates.isEmpty != false && !model.gestureActive && model.cropDraft == nil)
                    Button("Redo", action: model.redo).keyboardShortcut("z", modifiers: [.command,.shift]).disabled(!model.canRedo)
                }.padding(10)
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
            HSplitView {
                canvas.frame(minWidth: 340, minHeight: 250)
                properties.frame(minWidth: 170, idealWidth: 210, maxWidth: 280)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(model.message).font(.callout).accessibilityLabel("Editor status: " + model.message)
                if model.rendering { Text("Rendering preview…").font(.caption).accessibilityLabel("Rendering preview") }
                if model.previewFailed { Button("Retry Preview",action: model.retry).disabled(model.rendering) }
                HStack {
                    Button("Fit") { model.fit = true }
                    Menu(model.fit ? "Zoom: Fit" : "Zoom: \(Int(model.zoom * 100))%") {
                        ForEach([0.25,0.5,1.0,2.0,4.0],id: \.self) { value in
                            Button("\(Int(value * 100))%") { model.chooseZoom(value) }
                        }
                    }.frame(width: 150).accessibilityLabel("Zoom")
                    Spacer()
                    Button("Save Copy…", action: model.save).keyboardShortcut("s").disabled(true).help(AnnotationEditorModel.exportUnavailable)
                    Button("Save & Copy", action: model.save).disabled(true).help(AnnotationEditorModel.exportUnavailable)
                }
                Text("Original unchanged · Preview only").font(.caption).accessibilityLabel(model.document?.isDirty == true ? "Original unchanged. Preview only. Unsaved edits." : "Original unchanged. Preview only. No unsaved edits.")
                Text(AnnotationEditorModel.exportUnavailable).font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
        .onExitCommand { gestureCancelled = dragStart != nil; dragStart = nil; dragEnd = nil; model.cancelGesture() }
        .onChange(of: model.tool) { gestureCancelled = dragStart != nil; dragStart = nil; dragEnd = nil; model.cancelGesture() }
        .onChange(of: model.gestureActive) {
            if !model.gestureActive, dragStart != nil {
                gestureCancelled = true; dragStart = nil; dragEnd = nil
            }
        }
    }
    private var canvas: some View {
        GeometryReader { geometry in
            if let image = model.image, let crop = model.renderedCrop {
                let scale = model.fit ? min((geometry.size.width-48)/crop.width, (geometry.size.height-48)/crop.height) : model.zoom
                let size = CGSize(width: max(1,crop.width*scale), height: max(1,crop.height*scale))
                ScrollView([.horizontal,.vertical]) {
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1).resizable().frame(width: size.width,height: size.height)
                        if let draft = model.cropDraft { outline(draft, crop: crop, scale: scale, color: .yellow) }
                        if let selected = model.document?.state.marks.first(where: {$0.id == model.selected}) {
                            outline(selected.bounds, crop: crop, scale: scale, color: .accentColor)
                        }
                        if let start = dragStart, let end = dragEnd {
                            Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1,dash: [4]))
                                .frame(width: abs(end.x-start.x),height: abs(end.y-start.y))
                                .position(x: (start.x+end.x)/2,y: (start.y+end.y)/2)
                        }
                    }
                    .frame(width: size.width,height: size.height).clipped().contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard !gestureCancelled else { return }
                        if dragStart == nil { model.beginGesture() }
                        dragStart = value.startLocation; dragEnd = value.location
                    }.onEnded { value in
                        if !gestureCancelled && model.gestureActive { model.gesture(start: pixel(value.startLocation,crop: crop,scale: scale), end: pixel(value.location,crop: crop,scale: scale)) }
                        gestureCancelled = false; model.endGesture()
                        dragStart = nil; dragEnd = nil
                    })
                    .padding(24)
                }.accessibilityLabel("Annotation canvas, \(Int(crop.width)) by \(Int(crop.height)) pixels, \(model.document?.state.marks.count ?? 0) objects. Use the object list to select and edit annotations.")
                .focusable()
                .onKeyPress(phases: .down) { press in
                    let distance: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
                    switch press.key {
                    case .leftArrow: model.moveSelected(dx: -distance,dy: 0)
                    case .rightArrow: model.moveSelected(dx: distance,dy: 0)
                    case .upArrow: model.moveSelected(dx: 0,dy: distance)
                    case .downArrow: model.moveSelected(dx: 0,dy: -distance)
                    default: return .ignored
                    }
                    return .handled
                }
            } else {
                VStack {
                    if model.busy { ProgressView() }
                    Text(model.message)
                    Button(model.source == nil ? "Retry Image" : "Retry Preview", action: model.retry).disabled(model.busy || model.rendering)
                    if model.source == nil, !model.busy {
                        Button("Open Recents") { model.openRecents?() }.disabled(model.openRecents == nil)
                    }
                }
                    .padding().frame(maxWidth: .infinity,maxHeight: .infinity)
            }
        }.background(Color(nsColor: .underPageBackgroundColor))
    }
    private func pixel(_ point: CGPoint,crop: CGRect,scale: CGFloat) -> CGPoint {
        CGPoint(x: min(crop.maxX,max(crop.minX,crop.minX+point.x/scale)),y: min(crop.maxY,max(crop.minY,crop.maxY-point.y/scale)))
    }
    private func outline(_ rect: CGRect,crop: CGRect,scale: CGFloat,color: Color) -> some View {
        Rectangle().stroke(color,style: StrokeStyle(lineWidth: 2,dash: [5]))
            .frame(width: rect.width*scale,height: rect.height*scale)
            .offset(x: (rect.minX-crop.minX)*scale,y: (crop.maxY-rect.maxY)*scale)
            .allowsHitTesting(false)
    }
    private var properties: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 12) {
                if model.tool != .select {
                    Button(model.tool == .crop ? "Create Crop Preview" : "Add " + model.tool.rawValue,
                           action: model.addSelectedTool)
                        .disabled(!model.canAddSelectedTool)
                        .accessibilityHint("Creates a centered region that you can adjust with source-pixel controls below.")
                    Text("Coordinates use source pixels, measured from the bottom-left of the image.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Objects").font(.headline)
                ForEach(model.document?.state.marks ?? []) { mark in
                    Button { model.selected = mark.id; model.tool = .select } label: {
                        HStack { Text(mark.tool.rawValue); Spacer(); if model.selected == mark.id { Image(systemName:"checkmark") } }
                    }.accessibilityLabel(mark.accessibilityDescription)
                        .accessibilityValue(model.selected == mark.id ? "Selected" : "Not selected")
                }
                if let mark = model.document?.state.marks.first(where: {$0.id == model.selected}) {
                    Divider()
                    Text("Selected " + mark.tool.rawValue).font(.headline)
                    coordinate("Start X",value: mark.start.x) { value in model.changeSelected {$0.start.x = value} }
                    coordinate("Start Y",value: mark.start.y) { value in model.changeSelected {$0.start.y = value} }
                    coordinate("End X",value: mark.end.x) { value in model.changeSelected {$0.end.x = value} }
                    coordinate("End Y",value: mark.end.y) { value in model.changeSelected {$0.end.y = value} }
                    if mark.tool == .text {
                        TextField("Text",text: Binding(get: { mark.text },set: { value in model.changeSelected {$0.text = value} }),axis: .vertical)
                        number("Text size",value: mark.fontSize,range: 8...96) { value in model.changeSelected {$0.fontSize = value} }
                    }
                    if mark.tool == .blur {
                        Text("Visual blur is not secure redaction.").font(.caption)
                        number("Blur radius",value: mark.blurRadius,range: 8...48) { value in model.changeSelected {$0.blurRadius = value} }
                    } else {
                        number("Stroke width",value: mark.stroke,range: 1...32) { value in model.changeSelected {$0.stroke = value} }
                        ColorPicker("Color",selection: Binding(get: { Color(red: mark.color.red,green: mark.color.green,blue: mark.color.blue,opacity: mark.color.alpha) },set: { color in
                            guard let value = NSColor(color).usingColorSpace(.sRGB) else { return }
                            model.changeSelected {$0.color = AnnotationColor(red: value.redComponent,green: value.greenComponent,blue: value.blueComponent,alpha: value.alphaComponent)}
                        }))
                    }
                    HStack { Button("←") {model.moveSelected(dx:-1,dy:0)}.accessibilityLabel("Move left one pixel"); Button("→") {model.moveSelected(dx:1,dy:0)}.accessibilityLabel("Move right one pixel"); Button("↑") {model.moveSelected(dx:0,dy:1)}.accessibilityLabel("Move up one pixel"); Button("↓") {model.moveSelected(dx:0,dy:-1)}.accessibilityLabel("Move down one pixel") }
                    Button("Delete Object",action: model.deleteSelected)
                }
                if let crop = model.cropDraft {
                    Divider(); Text("Crop preview").font(.headline)
                    coordinate("Crop X", value: crop.minX) { value in model.changeCropDraft { $0.origin.x = value } }
                    coordinate("Crop Y", value: crop.minY) { value in model.changeCropDraft { $0.origin.y = value } }
                    coordinate("Crop Width", value: crop.width) { value in model.changeCropDraft { $0.size.width = value } }
                    coordinate("Crop Height", value: crop.height) { value in model.changeCropDraft { $0.size.height = value } }
                    Button("Apply Crop",action: model.applyCrop)
                    Button("Cancel Crop",action: model.cancelGesture)
                }
            }.padding(12)
        }
    }
    private func coordinate(_ label: String,value: CGFloat,set: @escaping @MainActor @Sendable (CGFloat)->Void) -> some View {
        HStack {
            Text(label)
            TextField(label,value: Binding(get:{Double(value)},set:{set(CGFloat($0))}),format:.number.precision(.fractionLength(0...1)))
                .textFieldStyle(.roundedBorder).accessibilityLabel(label + " in source pixels")
        }
    }
    private func number(_ label: String,value: Double,range: ClosedRange<Double>,set: @escaping @MainActor @Sendable (Double)->Void) -> some View {
        VStack(alignment: .leading) { Text("\(label): \(Int(value))"); Slider(value: Binding(get:{value},set:set),in:range,step:1).accessibilityLabel(label) }
    }
}
