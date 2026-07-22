import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct FlowRefetchLogicTests {
    static func main() {
        testIssuesTab()
        testPRsTab()
        testReposTabWithSelection()
        testReposTabWithoutSelection()
        testUnknownTab()
        print("PASS")
    }

    static func testIssuesTab() {
        let action = FlowRefetchLogic.action(for: "issues", hasSelectedRepo: false)
        expect(action == .refreshIssues, "the Issues tab should always refresh issues")
    }

    static func testPRsTab() {
        let action = FlowRefetchLogic.action(for: "prs", hasSelectedRepo: true)
        expect(action == .refreshPRs, "the PRs tab should always refresh PRs, regardless of repo selection")
    }

    static func testReposTabWithSelection() {
        let action = FlowRefetchLogic.action(for: "repos", hasSelectedRepo: true)
        expect(action == .refreshBranches, "restoring the Repos tab with a selected repo should refresh its branches")
    }

    static func testReposTabWithoutSelection() {
        let action = FlowRefetchLogic.action(for: "repos", hasSelectedRepo: false)
        expect(action == .none, "the Repos tab with no selected repo has nothing to refresh")
    }

    static func testUnknownTab() {
        let action = FlowRefetchLogic.action(for: "bogus", hasSelectedRepo: true)
        expect(action == .none, "an unrecognized tab value should never dispatch a fetch")
    }
}
