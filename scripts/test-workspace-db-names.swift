import Foundation

// Regression test for issue #15: a pane rename or an agent-assigned tab name (e.g. "pr review")
// must survive a real workspace dehydrate -> SQLite -> hydrate round trip, not just an in-memory
// one. Exercises WorkspaceDB's actual save/load path (the debug DB file under ~/.srota-debug),
// the same one Workspace.dehydrate()/hydrateIfNeeded() go through in the running app.

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct WorkspaceDBNameRoundTripTest {
    @MainActor
    static func main() async {
        let db = WorkspaceDB()
        let wsID = UUID().uuidString
        let tabID = UUID().uuidString
        let paneID = UUID().uuidString

        db.saveWorkspaceSession(WorkspaceSession(
            id: wsID, name: "regression-test-ws", folderName: "", folderTag: "",
            position: 0, lastCWD: "", lastAccessed: 0, isPinned: false
        ))
        db.saveTabsAndPanes(workspaceID: wsID, records: [
            (TabRecord(id: tabID, workspaceID: wsID, position: 0, initialCWD: "/tmp",
                       isSelected: true, name: "pr review"),
             [PaneRecord(id: paneID, tabID: tabID, isPrimary: true,
                         lx: 0, ly: 0, lw: 1, lh: 1,
                         initialCWD: "/tmp", position: 0, name: "custom pane name")])
        ])
        db.flushWritesBlocking()

        let restored = await db.loadWorkspaceRestoreRecords()
        db.deleteWorkspaceSession(id: wsID)
        db.flushWritesBlocking()

        guard let (_, tabs) = restored.first(where: { $0.0.id == wsID }) else {
            fputs("FAIL: workspace not found after DB round trip\n", stderr)
            exit(1)
        }
        guard let (tabRecord, panes) = tabs.first(where: { $0.0.id == tabID }) else {
            fputs("FAIL: tab not found after DB round trip\n", stderr)
            exit(1)
        }
        expect(tabRecord.name == "pr review",
               "tab name should survive dehydrate -> DB -> hydrate, got \(tabRecord.name)")
        guard let paneRecord = panes.first(where: { $0.id == paneID }) else {
            fputs("FAIL: pane not found after DB round trip\n", stderr)
            exit(1)
        }
        expect(paneRecord.name == "custom pane name",
               "pane name should survive dehydrate -> DB -> hydrate, got \(paneRecord.name)")

        print("PASS")
    }
}
