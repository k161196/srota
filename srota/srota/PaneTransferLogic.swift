import CoreGraphics
import Foundation

// Pure geometry behind cross-tab pane drag-and-drop (TerminalTab.movePane and
// TerminalContentView's drag handlers in ContentView.swift) — split out so it's exercisable
// without linking SwiftUI/Ghostty/the daemon. See scripts/test-pane-transfer-logic.swift.
enum PaneTransferLogic {
    // Halves a focused pane's rect horizontally: the existing pane keeps the left half, a
    // moved-in pane takes the right half. Mirrors TerminalTab.splitRight's math.
    static func splitLayout(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)
        -> (shrunk: (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat),
            new: (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)) {
        let half = w / 2
        return ((x, y, half, h), (x + half, y, half, h))
    }

    // Which tab chip (if any) a drag point lands on, excluding the dragged pane's own tab —
    // shared by onDragChanged (hover highlight) and onDragEnded (commit the move) so the two
    // paths can't drift apart.
    static func tabChipHit(at point: CGPoint, in frames: [UUID: CGRect], excluding ownTabID: UUID) -> UUID? {
        frames.first(where: { $0.key != ownTabID && $0.value.contains(point) })?.key
    }
}
