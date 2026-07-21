import SwiftUI

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct AgentRegionLogicTests {
    static func main() {
        testRegionIndex()
        testSelectOrSwitch()
        testAddToSplitNoViewedRegion()
        testAddToSplitGrowsViewedRegion()
        testAddToSplitNoOpWhenAlreadyMember()
        testAddToSplitMovesFromOtherRegion()
        print("PASS")
    }

    static func testRegionIndex() {
        let regions = [
            AgentRegion(id: UUID(), direction: .horizontal, memberIDs: ["a", "b"]),
            AgentRegion(id: UUID(), direction: .horizontal, memberIDs: ["c"]),
        ]
        expect(AgentRegionLogic.regionIndex(containing: "b", in: regions) == 0, "should find the region containing a grouped member")
        expect(AgentRegionLogic.regionIndex(containing: "c", in: regions) == 1, "should find a lone-member region")
        expect(AgentRegionLogic.regionIndex(containing: "z", in: regions) == nil, "should return nil for an unknown stableID")
    }

    static func testSelectOrSwitch() {
        let existing = AgentRegion(id: UUID(), direction: .horizontal, memberIDs: ["a", "b"])
        let r1 = AgentRegionLogic.selectOrSwitch(to: "b", regions: [existing])
        expect(r1.regions.count == 1, "selecting an existing grouped member must not create a new region")
        expect(r1.viewedRegionID == existing.id, "selecting a grouped member should view its own region")
        expect(r1.focusedStableID == "b", "selecting a member should focus it")

        let r2 = AgentRegionLogic.selectOrSwitch(to: "new", regions: [existing])
        expect(r2.regions.count == 2, "selecting an unopened agent should open it as its own new region")
        expect(r2.viewedRegionID != existing.id, "the new region should become the viewed one, not the pre-existing group")
        expect(r2.focusedStableID == "new", "selecting a new agent should focus it")
    }

    static func testAddToSplitNoViewedRegion() {
        let lingering = AgentRegion(id: UUID(), direction: .horizontal, memberIDs: ["x"])
        let r1 = AgentRegionLogic.addToSplit("x", direction: .vertical, regions: [lingering], viewedRegionID: nil)
        expect(r1.regions.count == 1, "re-adding an agent that's already open elsewhere shouldn't duplicate it")
        expect(r1.viewedRegionID == lingering.id, "nothing viewed yet + already-open agent should just switch to viewing it")

        let r2 = AgentRegionLogic.addToSplit("y", direction: .vertical, regions: [], viewedRegionID: nil)
        expect(r2.regions.count == 1, "nothing viewed yet + brand new agent should open exactly one new region")
        expect(r2.regions[0].direction == .vertical, "the new lone region should take the requested split direction")
    }

    static func testAddToSplitGrowsViewedRegion() {
        let region = AgentRegion(id: UUID(), direction: .horizontal, memberIDs: ["x"])
        let result = AgentRegionLogic.addToSplit("y", direction: .vertical, regions: [region], viewedRegionID: region.id)
        expect(result.regions.count == 1, "adding to the viewed region must not create a second region")
        expect(result.regions[0].memberIDs == ["x", "y"], "the new member should be appended to the viewed region")
        expect(result.regions[0].direction == .vertical, "a lone region's direction is still settable on its first real split")
        expect(result.focusedStableID == "y", "the newly added member should be focused")

        // Once a region has 2+ members, its direction is locked in regardless of which menu item grew it further.
        let grown = AgentRegionLogic.addToSplit("z", direction: .horizontal, regions: result.regions, viewedRegionID: region.id)
        expect(grown.regions[0].direction == .vertical, "an existing multi-member region must keep its original direction")
        expect(grown.regions[0].memberIDs == ["x", "y", "z"], "a third member should append, not replace")
    }

    static func testAddToSplitNoOpWhenAlreadyMember() {
        let region = AgentRegion(id: UUID(), direction: .horizontal, memberIDs: ["x", "y"])
        let result = AgentRegionLogic.addToSplit("y", direction: .vertical, regions: [region], viewedRegionID: region.id)
        expect(result.regions[0].memberIDs == ["x", "y"], "adding an agent already in the viewed region must be a no-op")
        expect(result.focusedStableID == nil, "a no-op must not report a focus change for the caller to apply")
    }

    static func testAddToSplitMovesFromOtherRegion() {
        let source = AgentRegion(id: UUID(), direction: .horizontal, memberIDs: ["a"])
        let target = AgentRegion(id: UUID(), direction: .horizontal, memberIDs: ["b"])
        let result = AgentRegionLogic.addToSplit("a", direction: .horizontal, regions: [source, target], viewedRegionID: target.id)
        expect(result.regions.count == 1, "moving an agent's only region should remove that now-empty region")
        expect(result.regions[0].memberIDs == ["b", "a"], "the moved agent should join the viewed region")
    }
}
