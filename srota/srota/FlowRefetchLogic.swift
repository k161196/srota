// Decides which fetch TasksPanel.fetchIfNeeded() should run for the current Flow sub-tab — pulled
// out of TasksPanelView so restoring a persisted tab/selection dispatches to the right fetch is
// unit-testable without a SwiftUI view harness (same rationale as AgentRegionLogic.swift /
// RepositoryFilterState.swift). `tab` takes TasksPanel.SubTab's raw string value rather than the
// type itself, so this file stays framework-free and scripts/test-flow-refetch-logic.swift can
// compile it standalone.
enum FlowRefetchAction: Equatable {
    case refreshIssues, refreshPRs, refreshBranches, none
}

enum FlowRefetchLogic {
    static func action(for tab: String, hasSelectedRepo: Bool) -> FlowRefetchAction {
        switch tab {
        case "repos": return hasSelectedRepo ? .refreshBranches : .none
        case "issues": return .refreshIssues
        case "prs": return .refreshPRs
        default: return .none
        }
    }
}
