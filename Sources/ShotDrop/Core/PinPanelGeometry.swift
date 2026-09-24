import CoreGraphics

/// Geometry uses global desktop coordinates, including screens left/below the primary display.
enum PinPanelGeometry {
    struct Recovery: Equatable {
        let frame: CGRect
        let maximumSize: CGSize
    }

    /// Reacts to display/move/wake events without following the pointer. A reachable
    /// user placement (including one spanning displays) survives unrelated changes.
    /// Only an oversized frame or inaccessible native title/close region is adjusted.
    static func recovery(frame: CGRect, visibleFrames: [CGRect], currentVisibleFrame: CGRect?) -> Recovery? {
        let screens = visibleFrames.filter(valid)
        guard valid(frame), !screens.isEmpty else { return nil }
        let selected: CGRect
        if let currentVisibleFrame, screens.contains(currentVisibleFrame), frame.intersects(currentVisibleFrame) {
            selected = currentVisibleFrame
        } else {
            selected = screens.max { area(frame.intersection($0)) < area(frame.intersection($1)) }!
        }
        let maximum = CGSize(width: selected.width * 0.7, height: selected.height * 0.7)
        // Keep the native title bar fixed while shrinking; resizing from the lower
        // edge would otherwise move the user's accessible close control.
        let size = CGSize(width: min(frame.width, maximum.width), height: min(frame.height, maximum.height))
        let resized = CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        let title = titleControlRegion(resized)
        let reachable = covered(title, by: screens)
        return Recovery(frame: reachable ? resized : clamp(resized, to: selected), maximumSize: maximum)
    }

    /// Native traffic lights plus enough title area to grab the panel. The geometry
    /// is conservative, uses desktop points, and never depends on backing scale.
    static func titleControlRegion(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + min(8, frame.width / 8), y: frame.maxY - min(28, frame.height),
               width: min(160, frame.width * 0.8), height: min(28, frame.height))
    }

    private static func covered(_ region: CGRect, by screens: [CGRect]) -> Bool {
        var remaining = [region]
        for screen in screens {
            remaining = remaining.flatMap { part -> [CGRect] in
                let intersection = part.intersection(screen)
                guard !intersection.isNull, !intersection.isEmpty else { return [part] }
                return [
                    CGRect(x: part.minX, y: part.minY, width: part.width, height: intersection.minY - part.minY),
                    CGRect(x: part.minX, y: intersection.maxY, width: part.width, height: part.maxY - intersection.maxY),
                    CGRect(x: part.minX, y: intersection.minY, width: intersection.minX - part.minX, height: intersection.height),
                    CGRect(x: intersection.maxX, y: intersection.minY, width: part.maxX - intersection.maxX, height: intersection.height)
                ].filter { !$0.isEmpty }
            }
            if remaining.isEmpty { return true }
        }
        return false
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { $0.isFinite }
            && rect.width > 0 && rect.height > 0
    }
    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }

    static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        let safe = visible.insetBy(dx: min(12, visible.width / 4), dy: min(12, visible.height / 4))
        let size = CGSize(width: min(frame.width, safe.width, visible.width * 0.7),
                          height: min(frame.height, safe.height, visible.height * 0.7))
        return CGRect(x: min(max(frame.minX, safe.minX), safe.maxX - size.width),
                      y: min(max(frame.minY, safe.minY), safe.maxY - size.height),
                      width: size.width, height: size.height)
    }

    static func placement(size: CGSize, visible: CGRect, occupied: [CGRect]) -> CGRect {
        var frame = clamp(CGRect(x: visible.maxX - size.width - 12, y: visible.minY + 12,
                                 width: size.width, height: size.height), to: visible)
        for other in occupied.sorted(by: { $0.minY < $1.minY }) where frame.intersects(other) {
            frame.origin.y = other.maxY + 12
        }
        if frame.maxY > visible.maxY - 12 {
            frame.origin = CGPoint(x: visible.maxX - frame.width - 12 - CGFloat(occupied.count) * 24,
                                   y: visible.maxY - frame.height - 12 - CGFloat(occupied.count) * 24)
        }
        return clamp(frame, to: visible)
    }

    static func imageSize(width: Int, height: Int, backingScale: CGFloat, zoom: CGFloat) -> CGSize {
        let scale = max(1, backingScale)
        let boundedZoom = min(4, max(0.25, zoom))
        return CGSize(width: CGFloat(width) / scale * boundedZoom,
                      height: CGFloat(height) / scale * boundedZoom)
    }
}

