import Foundation
import CoreGraphics

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct ResizeLogicTests {
    static func main() {
        expect(
            SidebarResizeLogic.updatedWidth(startWidth: 220, translationWidth: 40) == 260,
            "sidebar width should track drag translation from the drag start"
        )
        expect(
            SidebarResizeLogic.updatedWidth(startWidth: 220, translationWidth: -500) == 150,
            "sidebar width should clamp to the minimum width"
        )
        expect(
            SidebarResizeLogic.updatedWidth(startWidth: 220, translationWidth: 400) == 500,
            "sidebar width should clamp to the maximum width"
        )
        expect(
            SidebarResizeLogic.dividerThickness(sidebarVisible: false) == 0,
            "hidden sidebar should not leave a visible divider gap"
        )
        expect(
            SidebarResizeLogic.dividerThickness(sidebarVisible: true) == 9,
            "visible sidebar should show its full divider hit-target"
        )
        expect(
            PaneGroupResizeLogic.minWidth(total: 300, count: 6) < 60,
            "an even split among many members in a small window should not force a floor bigger than what an even share already gives it"
        )
        expect(
            PaneGroupResizeLogic.minWidth(total: 3000, count: 3) == 60,
            "plenty of space should still cap the per-member floor at the standard minimum"
        )
        expect(
            {
                let total: CGFloat = 300
                let count = 4
                let minW = PaneGroupResizeLogic.minWidth(total: total, count: count)
                // No siblings have grown yet, so this is the same as assuming everyone else sits at the floor.
                let maxW = PaneGroupResizeLogic.maxWidth(total: total, count: count, otherFixedSizes: Array(repeating: minW, count: count - 2))
                // The other (count - 1) members must always keep at least their floor even if this
                // one member is dragged all the way to maxW — otherwise the last (flexible) member
                // gets squeezed to zero.
                return maxW + minW * CGFloat(count - 1) <= total
            }(),
            "growing one member to its max must always leave every other member at least its floor"
        )
        expect(
            {
                let total: CGFloat = 400
                let count = 4
                // One sibling was already dragged large (well past the floor) — this member's max
                // must shrink to account for that ACTUAL size, not assume the sibling is still at
                // its independent floor.
                let sizeOfGrownSibling: CGFloat = 220
                let maxForThis = PaneGroupResizeLogic.maxWidth(total: total, count: count, otherFixedSizes: [sizeOfGrownSibling])
                let floor = PaneGroupResizeLogic.minWidth(total: total, count: count)
                return maxForThis <= total - sizeOfGrownSibling - floor
            }(),
            "one already-grown sibling must shrink this member's available max, not just its own independent bound"
        )
        expect(
            {
                // 3+ panes (4-way split: 3 fixed + 1 flexible last), each sequentially dragged to
                // its own computed max — every "other" size is the sibling's ACTUAL current size
                // (starting at the even share, exactly like AgentGroupView's `fixedSizes` dict),
                // not an assumed floor and not zero for untouched siblings. The running total, plus
                // the floor reserved for the flexible last pane, must never exceed `total`.
                let total: CGFloat = 500
                let count = 4
                let evenFraction = PaneGroupResizeLogic.evenFraction(count: count)
                var sizes = Array(repeating: evenFraction * total, count: count - 1)
                for i in 0..<sizes.count {
                    var others = sizes
                    others.remove(at: i)
                    sizes[i] = PaneGroupResizeLogic.maxWidth(total: total, count: count, otherFixedSizes: others)
                }
                let floor = PaneGroupResizeLogic.minWidth(total: total, count: count)
                return sizes.reduce(0, +) + floor <= total
            }(),
            "sequentially maxing out 3+ fixed members must never collapse the flexible last member"
        )
        expect(
            {
                // Once one pane has grabbed all the slack, a sibling's max must clamp down to its
                // OWN current size (no room to grow further) rather than allowing it past that —
                // dragging past "no room left" must be a no-op, not an overflow.
                let total: CGFloat = 500
                let count = 4
                let grownSize: CGFloat = 190
                let untouchedSize: CGFloat = 125
                let maxForUntouched = PaneGroupResizeLogic.maxWidth(total: total, count: count, otherFixedSizes: [grownSize, untouchedSize])
                return maxForUntouched <= untouchedSize
            }(),
            "a fixed pane with no room left to grow must have its max clamp at its own current size"
        )
        expect(
            PaneResizeLogic.clampedDelta(
                startSizes: [0.08, 0.07],
                negativeIndices: [0],
                translation: 0.2
            ) == nil,
            "impossible pane constraints should not produce a negative-size delta"
        )
        expect(
            PaneResizeLogic.clampedDelta(
                startSizes: [0.4, 0.4],
                negativeIndices: [0],
                translation: 0.2
            ) == 0.2,
            "pane resize delta should be clamped within the feasible range"
        )

        print("PASS")
    }
}
