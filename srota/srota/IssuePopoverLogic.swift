import Foundation

// Pure state/list-composition logic for the pane-header Issue Popover (see IssuePopover.swift for
// the SwiftUI surface). Pulled out so the navigation-restore and list-composition rules are
// unit-testable without a SwiftUI/AppKit harness — mirrors AgentRegionLogic.swift's split.
//
// The app target sets SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so every declaration below is
// explicitly `nonisolated` — these are plain Sendable value types fetched/decoded from
// `nonisolated`/`Task.detached` gh-CLI code in IssuePopover.swift, and without this, a Swift 6
// language-mode build would reject using their (implicitly MainActor-isolated) Decodable
// conformances and static members from that nonisolated context. IssuePopoverNavigationStore below
// is the one deliberate exception — it's genuinely @MainActor.

// Identifies a GitHub repo the popover is browsing — org+name, not a URL, so equality is exact
// regardless of "https://github.com/x/y" vs "git@github.com:x/y.git" spelling differences.
nonisolated struct IssueRepoIdentity: Hashable, Sendable {
    let org: String
    let name: String
}

// One row of `gh issue list`/`gh issue view` output — enough to render an Issue List row without
// fetching full issue detail (body/comments) for every row.
nonisolated struct GHIssueListItem: Identifiable, Decodable, Sendable {
    let number: Int
    let title: String
    let state: String
    let url: String
    let labels: [Label]
    let updatedAt: String
    struct Label: Decodable, Sendable, Hashable { let name: String }
    var id: Int { number }
}

// A Pane's remembered Issue Popover navigation: either the Issue List, or one selected issue.
// The Add form is deliberately not representable here — it's transient view state, never a
// remembered destination (see IssuePopoverLogic.destinationAfterClose).
nonisolated enum IssuePopoverDestination: Equatable, Sendable {
    case list
    case detail(Int)
}

// Keys the issue-detail cache by repo identity + number, not number alone — otherwise issue #12 in
// repo A and issue #12 in repo B (switching a Pane's repo) would collide and leak stale detail.
nonisolated struct IssueDetailCacheKey: Hashable, Sendable {
    let repo: IssueRepoIdentity
    let number: Int
}

nonisolated enum IssuePopoverLogic {
    static let openIssuesLimit = 50

    // Composes the OPEN ISSUES section: removes the Branch Issue by number (it's shown promoted,
    // above this section, so it must not also appear here), sorts by updatedAt descending (most
    // recently active first), and bounds the result — defensive even though the `gh` fetch itself
    // is already limited, so this rule holds regardless of what the fetch returns.
    static func composeOpenIssues(_ issues: [GHIssueListItem], branchIssueNumber: Int?) -> [GHIssueListItem] {
        var filtered = issues
        if let branchIssueNumber {
            filtered.removeAll { $0.number == branchIssueNumber }
        }
        filtered.sort { $0.updatedAt > $1.updatedAt }
        return Array(filtered.prefix(openIssuesLimit))
    }

    // A repository-identity change resets navigation to the Issue List; a branch-only change
    // (same repo, different branch) preserves whatever was remembered. No prior repo for this
    // Pane (first open) also starts on the Issue List.
    static func destination(
        forOpening repo: IssueRepoIdentity,
        previousRepo: IssueRepoIdentity?,
        rememberedDestination: IssuePopoverDestination
    ) -> IssuePopoverDestination {
        guard let previousRepo, previousRepo == repo else { return .list }
        return rememberedDestination
    }

    // Closing while an Add draft is in progress must discard it AND land the next open on the
    // Issue List — never on whatever detail/list destination was active before Add was opened,
    // since that would let transient form state masquerade as remembered navigation.
    static func destinationAfterClose(wasAdding: Bool, current: IssuePopoverDestination) -> IssuePopoverDestination {
        wasAdding ? .list : current
    }
}

// Per-Pane remembered Issue Popover destination — keyed by the Pane's stableID, kept only in
// memory (never written to WorkspaceDB) so it naturally resets on app restart. Wraps
// IssuePopoverLogic's pure reset/preserve rule with the bookkeeping of "what was this Pane's last
// known repo and destination." Lives in this Foundation-only file (not IssuePopover.swift) so the
// per-Pane isolation and successful-creation-selection rules stay reachable by the same
// swiftc self-check as the rest of this seam, without a SwiftUI/AppKit harness.
@MainActor
final class IssuePopoverNavigationStore {
    static let shared = IssuePopoverNavigationStore()
    private init() {}

    private var repoByPane: [String: IssueRepoIdentity] = [:]
    private var destinationByPane: [String: IssuePopoverDestination] = [:]

    // Call once when the popover opens (or its tracked repo changes). Applies the
    // reset-on-repo-change / preserve-on-branch-change rule and records the new state.
    func destination(paneID: String, repo: IssueRepoIdentity) -> IssuePopoverDestination {
        let resolved = IssuePopoverLogic.destination(
            forOpening: repo,
            previousRepo: repoByPane[paneID],
            rememberedDestination: destinationByPane[paneID] ?? .list
        )
        repoByPane[paneID] = repo
        destinationByPane[paneID] = resolved
        return resolved
    }

    func setDestination(paneID: String, _ destination: IssuePopoverDestination) {
        destinationByPane[paneID] = destination
    }
}
