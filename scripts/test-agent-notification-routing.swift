import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct AgentNotificationRoutingTests {
    static func main() {
        var state = AgentNotificationState()
        state.apply(status: .waitingForResponse, summary: "approve", timestamp: 10, ownerPaneID: "pane-2")
        state.clearIfOwned(byPaneID: "pane-2")
        expect(state.status == nil, "deleting the pane that owns a notification should clear tab status")
        expect(state.summary.isEmpty, "deleting the pane that owns a notification should clear summary")

        state.apply(status: .waitingForResponse, summary: "primary approve", timestamp: 11, ownerPaneID: "primary")
        state.clearIfOwned(byPaneID: "primary")
        expect(state.status == nil, "collapsing the primary pane should clear primary-owned status")

        let tabs = [
            AgentNotificationTabSnapshot(tabID: "live-tab", cwd: "/tmp/project", paneIDs: ["primary", "pane-1"])
        ]
        let staleTabMatch = AgentNotificationRouter.bestMatchingTabIndex(
            for: AgentNotificationEvent(tabID: "closed-tab", paneID: "pane-1", cwd: "/tmp/project"),
            in: tabs
        )
        expect(staleTabMatch == nil, "events with a stale explicit tab id should not fall back to cwd matching")

        let cwdMatch = AgentNotificationRouter.bestMatchingTabIndex(
            for: AgentNotificationEvent(tabID: nil, paneID: "pane-1", cwd: "/tmp/project/subdir"),
            in: tabs
        )
        expect(cwdMatch == 0, "events without tab id should match by live pane id before cwd")

        let stalePaneMatch = AgentNotificationRouter.bestMatchingTabIndex(
            for: AgentNotificationEvent(tabID: nil, paneID: "deleted-pane", cwd: "/tmp/project"),
            in: tabs
        )
        expect(stalePaneMatch == nil, "events with a stale explicit pane id should not fall back to cwd matching")

        let cwdOnlyMatch = AgentNotificationRouter.bestMatchingTabIndex(
            for: AgentNotificationEvent(tabID: nil, paneID: nil, cwd: "/tmp/project/subdir"),
            in: tabs
        )
        expect(cwdOnlyMatch == 0, "events without tab or pane id should still match by cwd")

        print("PASS")
    }
}
