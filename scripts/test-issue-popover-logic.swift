import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct IssuePopoverLogicTests {
    @MainActor
    static func main() {
        testExtractIssueNumberRecognizesExplicitFormats()
        testExtractIssueNumberRejectsUnrelatedNumbers()
        testComposeOpenIssuesRemovesBranchIssueDuplicate()
        testComposeOpenIssuesExcludesClosedBranchIssueByNumberToo()
        testComposeOpenIssuesOrdersByUpdatedAtDescending()
        testComposeOpenIssuesBoundsAt50()
        testDestinationResetsOnRepoChange()
        testDestinationPreservedOnBranchOnlyChange()
        testDestinationStartsOnListForNewPane()
        testDestinationAfterCloseDiscardsAddDraft()
        testDestinationAfterCloseKeepsNonAddDestination()
        testDetailCacheKeyIsolatesEqualNumbersAcrossRepos()
        testNavigationStoreIsolatesPanesFromEachOther()
        testNavigationStoreRemembersSuccessfulCreationSelection()
        print("PASS")
    }

    static func item(_ number: Int, updatedAt: String) -> GHIssueListItem {
        GHIssueListItem(number: number, title: "t\(number)", state: "OPEN", url: "", labels: [], updatedAt: updatedAt)
    }

    // MARK: - Branch parser (story 6: only explicit issue/<n> and issue-<n> select a Branch Issue)

    static func testExtractIssueNumberRecognizesExplicitFormats() {
        expect(extractIssueNumber(fromBranch: "issue/13") == 13, "issue/<n> should be recognized")
        expect(extractIssueNumber(fromBranch: "issue-13") == 13, "issue-<n> should be recognized")
        expect(extractIssueNumber(fromBranch: "issue/13-add-issue-list") == 13, "a descriptive suffix shouldn't change the parsed number")
        expect(extractIssueNumber(fromBranch: "issue-13-add-issue-list") == 13, "a descriptive suffix shouldn't change the parsed number")
    }

    static func testExtractIssueNumberRejectsUnrelatedNumbers() {
        expect(extractIssueNumber(fromBranch: "main") == nil, "an ordinary branch has no Branch Issue")
        expect(extractIssueNumber(fromBranch: "release-13") == nil, "a bare number on an unrelated branch must not be treated as an issue number")
        expect(extractIssueNumber(fromBranch: "hotfix/13") == nil, "a non-'issue' prefix must not be treated as a Branch Issue")
        expect(extractIssueNumber(fromBranch: "sprint13") == nil, "a number with no issue separator must not match")
    }

    // MARK: - Open-issues composition (stories 7, 8, 21, 28)

    static func testComposeOpenIssuesRemovesBranchIssueDuplicate() {
        let issues = [item(1, updatedAt: "2026-01-01T00:00:00Z"), item(2, updatedAt: "2026-01-02T00:00:00Z")]
        let result = IssuePopoverLogic.composeOpenIssues(issues, branchIssueNumber: 2)
        expect(result.map(\.number) == [1], "the promoted Branch Issue must not also appear in the open-issues section")
    }

    // A closed Branch Issue is still promoted (fetched independently, shown above the list), so its
    // number must still be excluded down here regardless of the state on the row that snuck into the
    // open-issues fetch (shouldn't normally happen since that fetch is --state open, but the dedup
    // itself must not be conditioned on state).
    static func testComposeOpenIssuesExcludesClosedBranchIssueByNumberToo() {
        var closedDuplicate = item(2, updatedAt: "2026-01-02T00:00:00Z")
        closedDuplicate = GHIssueListItem(
            number: closedDuplicate.number, title: closedDuplicate.title, state: "CLOSED",
            url: closedDuplicate.url, labels: closedDuplicate.labels, updatedAt: closedDuplicate.updatedAt
        )
        let issues = [item(1, updatedAt: "2026-01-01T00:00:00Z"), closedDuplicate]
        let result = IssuePopoverLogic.composeOpenIssues(issues, branchIssueNumber: 2)
        expect(result.map(\.number) == [1], "a closed Branch Issue must be excluded from OPEN ISSUES the same as an open one")
    }

    static func testComposeOpenIssuesOrdersByUpdatedAtDescending() {
        let issues = [
            item(1, updatedAt: "2026-01-01T00:00:00Z"),
            item(2, updatedAt: "2026-03-01T00:00:00Z"),
            item(3, updatedAt: "2026-02-01T00:00:00Z"),
        ]
        let result = IssuePopoverLogic.composeOpenIssues(issues, branchIssueNumber: nil)
        expect(result.map(\.number) == [2, 3, 1], "open issues should be ordered most-recently-updated first")
    }

    static func testComposeOpenIssuesBoundsAt50() {
        let issues = (1...60).map { item($0, updatedAt: "2026-01-01T00:00:\(String(format: "%02d", $0 % 60))Z") }
        let result = IssuePopoverLogic.composeOpenIssues(issues, branchIssueNumber: nil)
        expect(result.count == 50, "the recent working set must stay bounded at 50 even if more are supplied")
    }

    // MARK: - Navigation restore/reset (stories 17, 18, 19)

    static func testDestinationResetsOnRepoChange() {
        let repoA = IssueRepoIdentity(org: "acme", name: "widgets")
        let repoB = IssueRepoIdentity(org: "acme", name: "gadgets")
        let result = IssuePopoverLogic.destination(forOpening: repoB, previousRepo: repoA, rememberedDestination: .detail(42))
        expect(result == .list, "changing a Pane to a different repository must reset to the Issue List")
    }

    static func testDestinationPreservedOnBranchOnlyChange() {
        let repo = IssueRepoIdentity(org: "acme", name: "widgets")
        let result = IssuePopoverLogic.destination(forOpening: repo, previousRepo: repo, rememberedDestination: .detail(42))
        expect(result == .detail(42), "a branch-only change within the same repo must preserve the remembered destination")
    }

    static func testDestinationStartsOnListForNewPane() {
        let repo = IssueRepoIdentity(org: "acme", name: "widgets")
        let result = IssuePopoverLogic.destination(forOpening: repo, previousRepo: nil, rememberedDestination: .detail(1))
        expect(result == .list, "a Pane with no prior recorded repo should start on the Issue List")
    }

    // MARK: - Close-during-Add discards the draft's implied destination (stories 15, 16, 27)

    static func testDestinationAfterCloseDiscardsAddDraft() {
        let result = IssuePopoverLogic.destinationAfterClose(wasAdding: true, current: .detail(7))
        expect(result == .list, "closing during Add must discard the draft and land on the Issue List next open")
    }

    static func testDestinationAfterCloseKeepsNonAddDestination() {
        expect(IssuePopoverLogic.destinationAfterClose(wasAdding: false, current: .detail(7)) == .detail(7),
               "closing a selected issue (not Add) must preserve that issue as the destination")
        expect(IssuePopoverLogic.destinationAfterClose(wasAdding: false, current: .list) == .list,
               "closing the Issue List (not Add) must preserve the Issue List as the destination")
    }

    // MARK: - Detail cache key isolation (implementation decision: key by repo, not number alone)

    static func testDetailCacheKeyIsolatesEqualNumbersAcrossRepos() {
        let repoA = IssueRepoIdentity(org: "acme", name: "widgets")
        let repoB = IssueRepoIdentity(org: "acme", name: "gadgets")
        let keyA = IssueDetailCacheKey(repo: repoA, number: 12)
        let keyB = IssueDetailCacheKey(repo: repoB, number: 12)
        expect(keyA != keyB, "equal issue numbers in different repositories must not collide in the detail cache")
    }

    // MARK: - IssuePopoverNavigationStore (story 17: per-Pane isolation; story 26: a successful
    // creation's selection is what gets remembered)

    @MainActor
    static func testNavigationStoreIsolatesPanesFromEachOther() {
        let store = IssuePopoverNavigationStore.shared
        let repo = IssueRepoIdentity(org: "acme", name: "widgets")
        _ = store.destination(paneID: "pane-A", repo: repo)
        _ = store.destination(paneID: "pane-B", repo: repo)
        store.setDestination(paneID: "pane-A", .detail(5))
        expect(store.destination(paneID: "pane-A", repo: repo) == .detail(5),
               "pane A's own selected issue must be remembered")
        expect(store.destination(paneID: "pane-B", repo: repo) == .list,
               "one Pane's navigation must not leak into a different Pane browsing the same repo")
    }

    @MainActor
    static func testNavigationStoreRemembersSuccessfulCreationSelection() {
        let store = IssuePopoverNavigationStore.shared
        let repo = IssueRepoIdentity(org: "acme", name: "creations")
        _ = store.destination(paneID: "pane-create", repo: repo)
        // Mirrors IssuePopoverView.created(): a successful Add selects the new issue's detail.
        store.setDestination(paneID: "pane-create", .detail(99))
        expect(store.destination(paneID: "pane-create", repo: repo) == .detail(99),
               "the issue created by a successful Add must be the destination the next open restores")
    }
}
