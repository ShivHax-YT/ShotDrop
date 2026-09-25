import Foundation

enum AnnotationTool: String, CaseIterable, Identifiable, Sendable {
    case select = "Select", arrow = "Arrow", rectangle = "Rectangle", highlight = "Highlight", pixelate = "Pixelate", blur = "Visual Blur", text = "Text", crop = "Crop"
    var id: String { rawValue }
}

struct AnnotationColor: Equatable, Sendable {
    var red: Double = 1
    var green: Double = 0.27
    var blue: Double = 0.23
    var alpha: Double = 1
    var isValid: Bool { [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }
}

struct AnnotationMark: Identifiable, Equatable, Sendable {
    let id: UUID
    var tool: AnnotationTool
    var start: CGPoint
    var end: CGPoint
    var color = AnnotationColor()
    var stroke: Double = 2
    var text = "Text"
    var fontSize: Double = 24
    var blurRadius: Double = 24

    init(id: UUID = UUID(), tool: AnnotationTool, start: CGPoint, end: CGPoint) {
        self.id = id; self.tool = tool; self.start = start; self.end = end
    }
    var bounds: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
    var accessibilityDescription: String {
        let values = [start.x, start.y, end.x, end.y, bounds.minX, bounds.minY, bounds.width, bounds.height]
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 32_000_000 }) else {
            return "\(tool.rawValue), invalid geometry"
        }
        return "\(tool.rawValue), x \(Int(bounds.minX)), y \(Int(bounds.minY)), \(Int(bounds.width)) by \(Int(bounds.height)) pixels"
    }
}

struct AnnotationState: Equatable, Sendable {
    var marks: [AnnotationMark] = []
    var crop: CGRect
}

enum AnnotationFailure: Error, Equatable {
    case unavailable, invalidGeometry, tooLarge, tooManyEdits, invalidImage, renderingFailed, encodingFailed, busy, stale
}

/// Geometry is expressed in upright source pixels with origin at bottom-left.
struct AnnotationDocument: Sendable {
    static let maximumMarks = 100
    static let maximumUndo = 100
    static let maximumTextBytes = 64 * 1024
    let width: Int
    let height: Int
    private(set) var state: AnnotationState
    private(set) var revision: UInt64 = 0
    private(set) var undoStates: [AnnotationState] = []
    private(set) var redoStates: [AnnotationState] = []
    private var savedState: AnnotationState

    init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 32_000_000, height <= 32_000_000 / width else { throw AnnotationFailure.tooLarge }
        self.width = width; self.height = height
        state = AnnotationState(crop: CGRect(x: 0, y: 0, width: width, height: height))
        savedState = state
    }
    var isDirty: Bool { state != savedState }
    var extent: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    mutating func commit(_ next: AnnotationState) throws {
        try validate(next)
        guard next != state else { return }
        undoStates.append(state)
        if undoStates.count > Self.maximumUndo { undoStates.removeFirst() }
        redoStates.removeAll()
        state = next; revision &+= 1
    }
    mutating func undo() {
        guard let previous = undoStates.popLast() else { return }
        redoStates.append(state); state = previous; revision &+= 1
    }
    mutating func redo() {
        guard let next = redoStates.popLast() else { return }
        undoStates.append(state); state = next; revision &+= 1
    }
    mutating func markSaved(revision expected: UInt64) throws {
        guard expected == revision else { throw AnnotationFailure.stale }
        savedState = state
    }
    func validate(_ value: AnnotationState) throws {
        guard value.marks.count <= Self.maximumMarks else { throw AnnotationFailure.tooManyEdits }
        guard valid(value.crop), value.crop == value.crop.integral, extent.contains(value.crop) else { throw AnnotationFailure.invalidGeometry }
        var bytes = 0
        var ids = Set<UUID>()
        for mark in value.marks {
            guard ids.insert(mark.id).inserted, mark.tool != .select, mark.tool != .crop,
                  [mark.start.x, mark.start.y, mark.end.x, mark.end.y].allSatisfy(\.isFinite),
                  mark.start.x >= 0, mark.end.x >= 0, mark.start.y >= 0, mark.end.y >= 0,
                  mark.start.x <= CGFloat(width), mark.end.x <= CGFloat(width),
                  mark.start.y <= CGFloat(height), mark.end.y <= CGFloat(height),
                  mark.color.isValid, mark.stroke.isFinite, (1...32).contains(mark.stroke),
                  mark.fontSize.isFinite, (8...96).contains(mark.fontSize),
                  mark.blurRadius.isFinite, (8...48).contains(mark.blurRadius),
                  mark.text.utf8.count <= 4096 else { throw AnnotationFailure.invalidGeometry }
            bytes += mark.text.utf8.count
            guard bytes <= Self.maximumTextBytes else { throw AnnotationFailure.tooLarge }
            if mark.tool == .arrow {
                guard hypot(mark.end.x - mark.start.x, mark.end.y - mark.start.y) >= 1 else {
                    throw AnnotationFailure.invalidGeometry
                }
            } else if !valid(mark.bounds) { throw AnnotationFailure.invalidGeometry }
        }
    }
    private func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width >= 1 && rect.height >= 1
    }
}

struct AnnotationSource: Sendable {
    let reference: RecentFileReference
    let width: Int
    let height: Int
    let rgba: Data
}

struct AnnotationRaster: Sendable {
    let width: Int
    let height: Int
    let rgba: Data
}
