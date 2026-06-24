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
            SidebarResizeLogic.dividerThickness(sidebarVisible: false, isHovered: true) == 0,
            "hidden sidebar should not leave a visible divider gap"
        )
        expect(
            SidebarResizeLogic.dividerThickness(sidebarVisible: true, isHovered: true) == 3,
            "visible hovered sidebar should widen the divider hit affordance"
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
