import Foundation
import Observation

/// Durable Flow navigation and filter choices — see CONTEXT.md's "Flow View State" entry and
/// docs/adr/0001-persist-flow-view-state-in-json.md. One instance is owned at app scope and
/// injected into every window (srotaApp.swift), so all windows stay in sync and only one writer
/// ever touches the file.
@Observable @MainActor
final class FlowViewState {
    private struct Document: Codable {
        var selectedTab: TasksPanel.SubTab = .issues
        var repoFilterIDs: Set<String> = []
        var issueQuery = "is:issue is:open"
        var prQuery = "is:pr is:open"
        var repoSearch = ""
        var selectedRepoID: String? = nil
        var branchSearch = ""
    }

    var selectedTab: TasksPanel.SubTab = .issues
    var repoFilterIDs: Set<String> = []
    var issueQuery = "is:issue is:open"
    var prQuery = "is:pr is:open"
    var repoSearch = ""
    var selectedRepoID: String? = nil
    var branchSearch = ""

    private var savedData: Data?
    private let path: String

    /// `stateDirectory` defaults to the real per-build location (~/.srota/states/flow or
    /// ~/.srota-debug/states/flow); the self-check below points it at a temp directory instead —
    /// the one behavioral seam this gets tested through, per the issue's testing decisions.
    init(stateDirectory: String = NSHomeDirectory() + "/\(Srota.dir)/states/flow") {
        path = stateDirectory + "/state.json"
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let doc = try? JSONDecoder().decode(Document.self, from: data)
        else { return }
        apply(doc)
        savedData = try? JSONEncoder().encode(doc)
    }

    func save() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let doc = Document(selectedTab: selectedTab, repoFilterIDs: repoFilterIDs, issueQuery: issueQuery,
                            prQuery: prQuery, repoSearch: repoSearch, selectedRepoID: selectedRepoID,
                            branchSearch: branchSearch)
        guard let data = try? JSONEncoder().encode(doc), data != savedData else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            savedData = data
        } catch {
            // ponytail: no retry queue — the next durable change calls save() again on its own.
            print("FlowViewState: save failed: \(error)")
        }
    }

    private func apply(_ doc: Document) {
        selectedTab = doc.selectedTab
        repoFilterIDs = doc.repoFilterIDs
        issueQuery = doc.issueQuery
        prQuery = doc.prQuery
        repoSearch = doc.repoSearch
        selectedRepoID = doc.selectedRepoID
        branchSearch = doc.branchSearch
    }

    /// Drops filter/selection IDs for repos no longer connected. No-ops on an empty catalog —
    /// WorkspaceDB.repos starts empty until its async startup load completes, and pruning against
    /// that transient state would wipe a valid persisted filter before it ever had a chance to load.
    /// ponytail: this also skips pruning if the user genuinely disconnects every repo, leaving
    /// stale IDs in the saved document — harmless, since connectedRepos/selectedRepo already
    /// resolve to empty/nil against an empty catalog regardless, and the next real repo list
    /// prunes them for good. Telling the two empty cases apart needs a "has WorkspaceDB loaded
    /// at least once" flag that doesn't exist today; add one if this ever needs to be exact.
    func pruneRepoIDs(existing: [String]) {
        guard !existing.isEmpty else { return }
        let ids = Set(existing)
        if !repoFilterIDs.isEmpty { repoFilterIDs.formIntersection(ids) }
        if let selectedRepoID, !ids.contains(selectedRepoID) { self.selectedRepoID = nil }
    }

    /// Settings → State → Reset Flow View: restores every default immediately (so every open
    /// window reflects it) and persists that default document through the normal save path.
    func reset() {
        apply(Document())
        save()
    }

    #if DEBUG
    /// Runnable regression check — no XCTest target exists in this project (see
    /// EditorsStore.runSelfCheck for the prior art this follows), so this asserts on every debug
    /// launch instead (see srotaApp.init()). Points a fresh instance at a temp directory rather
    /// than the real ~/.srota path.
    static func runSelfCheck() {
        let root = NSTemporaryDirectory() + "srota-flow-selfcheck-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Missing file → current defaults.
        let fresh = FlowViewState(stateDirectory: root + "/fresh")
        assert(fresh.selectedTab == .issues && fresh.repoFilterIDs.isEmpty && fresh.issueQuery == "is:issue is:open"
               && fresh.prQuery == "is:pr is:open" && fresh.repoSearch.isEmpty && fresh.selectedRepoID == nil
               && fresh.branchSearch.isEmpty)

        // Every persisted field survives a save/load round trip.
        fresh.selectedTab = .prs
        fresh.repoFilterIDs = ["a", "b"]
        fresh.issueQuery = "is:issue is:open label:bug"
        fresh.prQuery = "is:pr is:open author:@me"
        fresh.repoSearch = "srota"
        fresh.selectedRepoID = "repo-1"
        fresh.branchSearch = "issue/"
        fresh.save()

        let reloaded = FlowViewState(stateDirectory: root + "/fresh")
        assert(reloaded.selectedTab == .prs)
        assert(reloaded.repoFilterIDs == ["a", "b"])
        assert(reloaded.issueQuery == "is:issue is:open label:bug")
        assert(reloaded.prQuery == "is:pr is:open author:@me")
        assert(reloaded.repoSearch == "srota")
        assert(reloaded.selectedRepoID == "repo-1")
        assert(reloaded.branchSearch == "issue/")

        // Malformed JSON → complete default state, and the bad file is left untouched during load.
        let malformedDir = root + "/malformed"
        try? FileManager.default.createDirectory(atPath: malformedDir, withIntermediateDirectories: true)
        let malformedPath = malformedDir + "/state.json"
        let garbage = Data("not json".utf8)
        try? garbage.write(to: URL(fileURLWithPath: malformedPath))
        let malformed = FlowViewState(stateDirectory: malformedDir)
        assert(malformed.selectedTab == .issues && malformed.issueQuery == "is:issue is:open")
        assert((try? Data(contentsOf: URL(fileURLWithPath: malformedPath))) == garbage)

        // Unknown repo IDs are pruned once a catalog is supplied; an empty catalog (async startup) is a no-op.
        let pruning = FlowViewState(stateDirectory: root + "/pruning")
        pruning.repoFilterIDs = ["keep", "stale"]
        pruning.selectedRepoID = "stale"
        pruning.pruneRepoIDs(existing: [])
        assert(pruning.repoFilterIDs == ["keep", "stale"] && pruning.selectedRepoID == "stale")
        pruning.pruneRepoIDs(existing: ["keep"])
        assert(pruning.repoFilterIDs == ["keep"] && pruning.selectedRepoID == nil)

        // Save failure leaves in-memory state unchanged: force the write to fail by putting a
        // directory where the state file needs to go.
        let failDir = root + "/fail"
        try? FileManager.default.createDirectory(atPath: failDir + "/state.json", withIntermediateDirectories: true)
        let failing = FlowViewState(stateDirectory: failDir)
        failing.issueQuery = "is:issue is:open unsaved"
        failing.save()
        assert(failing.issueQuery == "is:issue is:open unsaved")

        // Reset restores every default immediately and persists it for a subsequent load.
        reloaded.reset()
        assert(reloaded.selectedTab == .issues && reloaded.repoFilterIDs.isEmpty && reloaded.issueQuery == "is:issue is:open"
               && reloaded.prQuery == "is:pr is:open" && reloaded.repoSearch.isEmpty && reloaded.selectedRepoID == nil
               && reloaded.branchSearch.isEmpty)
        let afterReset = FlowViewState(stateDirectory: root + "/fresh")
        assert(afterReset.selectedTab == .issues && afterReset.issueQuery == "is:issue is:open")
    }
    #endif
}
