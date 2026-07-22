import Foundation

// The repository scope whose issues and pull requests are shown — see CONTEXT.md's "Repository
// Filter" glossary entry. Three explicit states rather than collapsing an empty selection into
// "all repos": that collapse was the bug this type exists to fix (issue #11). Pulled out of
// TasksPanelView so the transition/collapsing rules are unit-testable without a SwiftUI view
// harness (same rationale as AgentRegionLogic.swift).
enum RepositoryFilterState: Equatable, Codable {
    case all
    case none
    case subset(Set<String>)

    enum Action: CaseIterable, Hashable {
        case clear, showAll

        var title: String {
            switch self {
            case .clear: return "Clear"
            case .showAll: return "Show all"
            }
        }
    }

    // Toggles `id` against the "all connected repos" baseline, not the working subset alone —
    // otherwise unchecking one repo out of hundreds would scope every fetch to the other 199.
    // Collapses to `.all`/`.none` when the result matches every repo or no repo, so the filter
    // always reports its canonical bulk state instead of an equivalent-but-distinct subset.
    static func toggling(_ id: String, in state: RepositoryFilterState, allIDs: Set<String>) -> RepositoryFilterState {
        var current: Set<String>
        switch state {
        case .all: current = allIDs
        case .none: current = []
        case .subset(let ids): current = ids
        }
        if current.contains(id) { current.remove(id) } else { current.insert(id) }
        if current.isEmpty { return .none }
        if current == allIDs { return .all }
        return .subset(current)
    }

    // Removing a repo prunes it from an explicit subset; losing the last member lands on `.none`,
    // never silently widening back to `.all`. `.all`/`.none` are unaffected — `.all` keeps meaning
    // "every connected repo" without tracking membership, and `.none` stays empty.
    static func removingRepo(_ id: String, from state: RepositoryFilterState) -> RepositoryFilterState {
        guard case .subset(var ids) = state else { return state }
        ids.remove(id)
        return ids.isEmpty ? .none : .subset(ids)
    }

    // The bulk actions themselves: Clear always lands on `.none`, Show all always on `.all`,
    // regardless of the state they're applied from — the model is the source of truth for this
    // transition rather than the view assigning `.none`/`.all` directly.
    // Bulk version of removingRepo, run when the connected-repo catalog changes wholesale (e.g.
    // FlowViewState.pruneRepoIDs). Never collapses to `.all` even if the surviving subset happens
    // to match `existing` — that promotion is a deliberate user action (toggling every repo),
    // not a side effect of other repos disconnecting.
    static func pruning(_ state: RepositoryFilterState, keeping existing: Set<String>) -> RepositoryFilterState {
        guard case .subset(var ids) = state else { return state }
        ids.formIntersection(existing)
        return ids.isEmpty ? .none : .subset(ids)
    }

    func applying(_ action: Action) -> RepositoryFilterState {
        switch action {
        case .clear: return .none
        case .showAll: return .all
        }
    }

    func isSelected(_ id: String) -> Bool {
        switch self {
        case .all: return true
        case .none: return false
        case .subset(let ids): return ids.contains(id)
        }
    }

    // All shows Clear; None shows Show all; a subset shows both, Clear first.
    var availableActions: [Action] {
        switch self {
        case .all: return [.clear]
        case .none: return [.showAll]
        case .subset: return [.clear, .showAll]
        }
    }

    var summaryText: String {
        switch self {
        case .all: return "All repositories selected"
        case .none: return "No repositories selected"
        case .subset(let ids): return "\(ids.count) selected"
        }
    }
}
