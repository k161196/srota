import CoreGraphics

enum SidebarResizeLogic {
    static let minWidth: CGFloat = 150
    static let maxWidth: CGFloat = 500

    static func updatedWidth(
        startWidth: CGFloat, translationWidth: CGFloat,
        minWidth: CGFloat = minWidth, maxWidth: CGFloat = maxWidth
    ) -> CGFloat {
        max(minWidth, min(maxWidth, startWidth + translationWidth))
    }

    // A hidden sidebar must collapse its divider to 0, not just fade/disable it — otherwise the
    // divider keeps reserving its hit-target width next to a sidebar that's already width 0.
    static func dividerThickness(sidebarVisible: Bool) -> CGFloat {
        sidebarVisible ? 9 : 0
    }
}

// A group's members are always evenly tiled; only the fixed (non-last) members carry a divider.
// Pulled out of AgentGroupView (a GeometryReader-driven SwiftUI body) so the sizing math — the
// exact thing that broke in small windows/after membership changes — is unit-testable on its own.
enum PaneGroupResizeLogic {
    // Smaller than the sidebar's 150pt floor: a split can hold many more members than a single
    // sidebar divider, so the floor has to shrink with member count, not be reused verbatim.
    static let minPaneSize: CGFloat = 60

    static func evenFraction(count: Int) -> CGFloat {
        count == 0 ? 0 : 1 / CGFloat(count)
    }

    static func minWidth(total: CGFloat, count: Int) -> CGFloat {
        count == 0 ? 0 : min(minPaneSize, total / CGFloat(count))
    }

    // Bounds one fixed member's width by what's actually left over, given every OTHER fixed
    // member's CURRENT size (not an assumed floor) plus a reserved floor for the flexible last
    // member. Assuming every sibling sits at the floor was the bug: with 3+ panes, two siblings
    // could each be dragged toward their own independently-computed max and, added together,
    // exceed `total` — this only checks each pane in isolation, so it has to be recomputed from
    // the siblings' live sizes on every render, not cached as a per-count constant.
    static func maxWidth(total: CGFloat, count: Int, otherFixedSizes: [CGFloat]) -> CGFloat {
        let floor = minWidth(total: total, count: count)
        let reserved = otherFixedSizes.reduce(0, +) + floor // floor reserved for the flexible last member
        return max(floor, total - reserved)
    }
}

enum PaneResizeLogic {
    static let minFraction: CGFloat = 0.1

    static func clampedDelta(
        startSizes: [CGFloat],
        negativeIndices: Set<Int>,
        translation: CGFloat,
        minimumFraction: CGFloat = minFraction
    ) -> CGFloat? {
        guard !startSizes.isEmpty else { return nil }

        var lowerBound: CGFloat = -.greatestFiniteMagnitude
        var upperBound: CGFloat = .greatestFiniteMagnitude

        for (index, size) in startSizes.enumerated() {
            if negativeIndices.contains(index) {
                lowerBound = max(lowerBound, minimumFraction - size)
            } else {
                upperBound = min(upperBound, size - minimumFraction)
            }
        }

        guard lowerBound <= upperBound else { return nil }
        return max(lowerBound, min(upperBound, translation))
    }
}
