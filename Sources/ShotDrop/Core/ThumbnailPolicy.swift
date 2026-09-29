import CoreGraphics
import Foundation

/// Pure interaction decisions shared by the panel and its focused tests.
enum ThumbnailPolicy {
    static let maximumSize = CGSize(width: 256, height: 166)
    static let edgeInset: CGFloat = 12
    static let dragThreshold: CGFloat = 7
    static let idleSeconds: TimeInterval = 7
    static let fadeSeconds: TimeInterval = 0.25

    static func frame(in visibleFrame: CGRect) -> CGRect {
        let availableWidth = max(0, visibleFrame.width - edgeInset * 2)
        let availableHeight = max(0, visibleFrame.height - edgeInset * 2)
        let scale = min(1, availableWidth / maximumSize.width, availableHeight / maximumSize.height)
        let size = CGSize(width: maximumSize.width * scale, height: maximumSize.height * scale)
        return CGRect(x: visibleFrame.maxX - edgeInset - size.width,
                      y: visibleFrame.minY + edgeInset,
                      width: size.width, height: size.height)
    }

    static func shouldDismissSwipe(translation: CGSize, velocity: CGSize, trailingIsRight: Bool = true) -> Bool {
        let direction: CGFloat = trailingIsRight ? 1 : -1
        let horizontal = translation.width * direction
        guard horizontal > 0, abs(translation.width) > abs(translation.height) else { return false }
        return horizontal >= 80 || (horizontal >= 24 && velocity.width * direction >= 600)
    }
}

struct ThumbnailCapture: Equatable, Identifiable {
    let id: UUID
    let finalURL: URL
    let copyFailed: Bool
}

/// A newer capture cannot retarget a drag or deliberate focused action.
struct ThumbnailQueue {
    private(set) var visible: ThumbnailCapture?
    private(set) var pending: ThumbnailCapture?
    private(set) var isLocked = false

    mutating func receive(_ capture: ThumbnailCapture) {
        if isLocked {
            pending = capture
        } else {
            visible = capture
            pending = nil
        }
    }

    mutating func lock(id: UUID) {
        guard visible?.id == id else { return }
        isLocked = true
    }

    mutating func unlock(id: UUID) {
        guard visible?.id == id, isLocked else { return }
        isLocked = false
        if let pending {
            visible = pending
            self.pending = nil
        }
    }

    mutating func dismiss(id: UUID) {
        guard visible?.id == id else { return }
        visible = pending
        pending = nil
        isLocked = false
    }

    mutating func clear() {
        visible = nil
        pending = nil
        isLocked = false
    }
}
