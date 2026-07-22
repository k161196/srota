import Foundation
import CoreGraphics

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct PaneTransferLogicTests {
    static func main() {
        let split = PaneTransferLogic.splitLayout(x: 0, y: 0, w: 1, h: 1)
        expect(split.shrunk.x == 0 && split.shrunk.w == 0.5, "shrunk half keeps the original origin and halves width")
        expect(split.new.x == 0.5 && split.new.w == 0.5, "new half starts where the shrunk half ends")
        expect(split.shrunk.h == 1 && split.new.h == 1, "height is untouched by a horizontal split")

        let offset = PaneTransferLogic.splitLayout(x: 0.5, y: 0.25, w: 0.4, h: 0.6)
        expect(offset.shrunk.x == 0.5 && offset.shrunk.w == 0.2, "split respects a non-origin starting rect")
        expect(offset.new.x == 0.7 && offset.new.y == 0.25, "new half's y matches the source rect, x is shrunk-half's end")

        let tabA = UUID(), tabB = UUID(), tabC = UUID()
        let frames: [UUID: CGRect] = [
            tabA: CGRect(x: 0, y: 0, width: 100, height: 30),
            tabB: CGRect(x: 100, y: 0, width: 100, height: 30)
        ]
        expect(
            PaneTransferLogic.tabChipHit(at: CGPoint(x: 50, y: 15), in: frames, excluding: tabB) == tabA,
            "a point inside tab A's chip should hit tab A"
        )
        expect(
            PaneTransferLogic.tabChipHit(at: CGPoint(x: 50, y: 15), in: frames, excluding: tabA) == nil,
            "excluding the pane's own tab must not report a self-hit even if the point is inside its chip"
        )
        expect(
            PaneTransferLogic.tabChipHit(at: CGPoint(x: 150, y: 15), in: frames, excluding: tabA) == tabB,
            "a point inside tab B's chip should hit tab B"
        )
        expect(
            PaneTransferLogic.tabChipHit(at: CGPoint(x: 500, y: 15), in: frames, excluding: tabA) == nil,
            "a point outside every chip should not hit anything"
        )
        expect(
            PaneTransferLogic.tabChipHit(at: CGPoint(x: 50, y: 15), in: frames, excluding: tabC) == tabA,
            "excluding an unrelated tab ID should not affect hit-testing against other tabs"
        )

        print("PASS")
    }
}
