import Foundation

/// Content-fit sizing for the Recent panel. Chrome stays outside the scrollable body;
/// callers must allow the empty state to scroll too when its measured copy exceeds the budget.
struct RecentMenuLayout: Equatable, Sendable {
    static let maximumPanelHeight: CGFloat = 560
    static let screenMargin: CGFloat = 32

    let bodyHeight: CGFloat
    let panelHeight: CGFloat
    let isBodyScrollable: Bool

    static func measure(
        rowCount: Int,
        chromeHeight: CGFloat,
        emptyHeight: CGFloat,
        estimatedRowHeight: CGFloat,
        measuredTotalRowHeight: CGFloat? = nil,
        availableHeight: CGFloat
    ) -> Self {
        let screen = availableHeight.isFinite ? max(0, availableHeight) : 0
        let cap = min(maximumPanelHeight, max(0, screen - screenMargin))
        // An invalid chrome measurement cannot grant an unbounded content area.
        let chrome = chromeHeight.isFinite ? min(cap, max(0, chromeHeight)) : cap
        let budget = max(0, cap - chrome)
        let count = min(20, max(0, rowCount))
        let desiredBody: CGFloat
        if count == 0 {
            desiredBody = emptyHeight.isFinite ? max(0, emptyHeight) : cap
        } else if let measuredTotalRowHeight,
                  measuredTotalRowHeight.isFinite, measuredTotalRowHeight > 0 {
            desiredBody = measuredTotalRowHeight
        } else {
            let estimate = estimatedRowHeight.isFinite && estimatedRowHeight > 0
                ? estimatedRowHeight : 64
            // Clamp before multiplying to avoid overflow from hostile/invalid measurements.
            // cap + 1 preserves the overflow signal even if the body has the entire cap.
            desiredBody = min(estimate, cap + 1) * CGFloat(count)
        }
        let body = min(budget, desiredBody)
        return Self(bodyHeight: body, panelHeight: chrome + body,
                    isBodyScrollable: desiredBody > budget)
    }

    /// Animate only the containing panel's size, never individual row insertion/reordering.
    static func transitionDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : 0.16
    }
}
