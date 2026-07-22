import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct RepositoryFilterStateTests {
    static func main() {
        testTogglingFromAll()
        testTogglingFromNone()
        testTogglingWithinSubset()
        testTogglingCollapsesToAllOrNone()
        testTogglingWithSingleConnectedRepo()
        testRemovingRepo()
        testIsSelected()
        testAvailableActions()
        testApplyingActions()
        testSummaryText()
        print("PASS")
    }

    static func testTogglingFromAll() {
        let allIDs: Set<String> = ["a", "b", "c"]
        let result = RepositoryFilterState.toggling("a", in: .all, allIDs: allIDs)
        expect(result == .subset(["b", "c"]), "deselecting one repo out of all should produce a subset of the rest")
    }

    static func testTogglingFromNone() {
        let allIDs: Set<String> = ["a", "b", "c"]
        let result = RepositoryFilterState.toggling("a", in: .none, allIDs: allIDs)
        expect(result == .subset(["a"]), "selecting a repo from None should create a one-repository subset")
    }

    static func testTogglingWithinSubset() {
        let allIDs: Set<String> = ["a", "b", "c"]
        let added = RepositoryFilterState.toggling("b", in: .subset(["a"]), allIDs: allIDs)
        expect(added == .subset(["a", "b"]), "adding a repo to a subset should grow it")

        let removed = RepositoryFilterState.toggling("a", in: .subset(["a", "b"]), allIDs: allIDs)
        expect(removed == .subset(["b"]), "removing one member of a two-repo subset should leave the other")
    }

    static func testTogglingCollapsesToAllOrNone() {
        let allIDs: Set<String> = ["a", "b"]
        let selectingLast = RepositoryFilterState.toggling("b", in: .subset(["a"]), allIDs: allIDs)
        expect(selectingLast == .all, "selecting every repo individually should resolve to All")

        let deselectingLast = RepositoryFilterState.toggling("a", in: .subset(["a"]), allIDs: allIDs)
        expect(deselectingLast == .none, "deselecting the last repo individually should resolve to None, not All")
    }

    static func testTogglingWithSingleConnectedRepo() {
        // With only one connected repo total, deselecting it from All is also deselecting the
        // last repo — must land on None, not a one-member subset equal to All in disguise.
        let result = RepositoryFilterState.toggling("a", in: .all, allIDs: ["a"])
        expect(result == .none, "deselecting the only connected repo from All should resolve to None")
    }

    static func testRemovingRepo() {
        let pruned = RepositoryFilterState.removingRepo("a", from: .subset(["a", "b"]))
        expect(pruned == .subset(["b"]), "removing a repo should prune it from an explicit subset")

        let collapsed = RepositoryFilterState.removingRepo("a", from: .subset(["a"]))
        expect(collapsed == .none, "removing the last repo in a subset should produce None, never All")

        expect(RepositoryFilterState.removingRepo("a", from: .all) == .all, "removing a repo must not change All — it has no tracked membership")
        expect(RepositoryFilterState.removingRepo("a", from: .none) == .none, "removing a repo must not change None")
    }

    static func testIsSelected() {
        expect(RepositoryFilterState.all.isSelected("x"), "All must select any repo, including newly connected ones")
        expect(!RepositoryFilterState.none.isSelected("x"), "None must select no repo")
        expect(RepositoryFilterState.subset(["x"]).isSelected("x"), "a subset must select its own member")
        expect(!RepositoryFilterState.subset(["x"]).isSelected("y"), "a subset must not select a repo outside it")
    }

    static func testAvailableActions() {
        expect(RepositoryFilterState.all.availableActions == [.clear], "All should only expose Clear")
        expect(RepositoryFilterState.none.availableActions == [.showAll], "None should only expose Show all")
        expect(RepositoryFilterState.subset(["x"]).availableActions == [.clear, .showAll], "a subset should expose Clear then Show all")
    }

    static func testApplyingActions() {
        expect(RepositoryFilterState.all.applying(.clear) == .none, "Clear from All should produce None")
        expect(RepositoryFilterState.subset(["x"]).applying(.clear) == .none, "Clear from a subset should produce None")
        expect(RepositoryFilterState.subset(["x"]).applying(.showAll) == .all, "Show all from a subset should produce All")
        expect(RepositoryFilterState.none.applying(.showAll) == .all, "Show all from None should produce All")
    }

    static func testSummaryText() {
        expect(RepositoryFilterState.all.summaryText == "All repositories selected", "All should summarize as 'All repositories selected'")
        expect(RepositoryFilterState.none.summaryText == "No repositories selected", "None should summarize as 'No repositories selected'")
        expect(RepositoryFilterState.subset(["x", "y"]).summaryText == "2 selected", "a subset should summarize with its count")
    }
}
