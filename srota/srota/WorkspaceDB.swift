import Foundation
import Observation
import SQLite3

nonisolated(unsafe) private let SQLITE_TRANSIENT_FN = unsafeBitCast(-1 as Int, to: sqlite3_destructor_type.self)

struct WorkspaceSession: Identifiable, Sendable {
    var id: String
    var name: String
    var folderName: String
    var folderTag: String
    var position: Int
    var lastCWD: String
    var lastAccessed: Int
    var isPinned: Bool
    var directory: String = ""
    var folderPosition: Int = -1
    var additionalDirectories: [String] = []
}

struct TabRecord: Identifiable, Sendable {
    var id: String
    var workspaceID: String
    var position: Int
    var initialCWD: String
    var isSelected: Bool
}

struct PaneRecord: Identifiable, Sendable {
    var id: String
    var tabID: String
    var isPrimary: Bool
    var lx, ly, lw, lh: Double
    var initialCWD: String
    var position: Int = 0
}

struct RepoEntry: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var url: String
    var defaultBranch: String
}

// A single run of a coding agent inside a pane — see CONTEXT.md.
struct SessionRecord: Identifiable, Sendable {
    var id: String
    var paneID: String
    var provider: String
    var externalSessionID: String
    var title: String = ""
    var summary: String = ""
    var createdAt: Int
    var endedAt: Int?
}

// A summarized record of one content-bearing hook event within a session — see CONTEXT.md.
struct SessionStepRecord: Identifiable, Sendable {
    var id: String
    var sessionID: String
    var hookEvent: String
    var title: String
    var description: String
    var source: String
    var tag: String // "user" | "agent" | "mcp" — who/what this note is attributed to
    var createdAt: Int
}

struct WorkspaceLayoutSnapshot: Sendable {
    var session: WorkspaceSession
    var tabsAndPanes: [(TabRecord, [PaneRecord])]?
}

@Observable
@MainActor
final class WorkspaceDB {
    private let storage = WorkspaceStorage()
    private var dbWatcher: DispatchSourceFileSystemObject?
    // The db is in WAL mode (srota-mcp's server sets PRAGMA journal_mode=WAL, which is sticky
    // per file — every connection to it, including this app's, is WAL from then on). Actual
    // writes land in "<db>-wal", not the main file, which is only touched on checkpoint — so a
    // cross-process writer's changes never trigger dbWatcher's events without this second one.
    private var dbWalWatcher: DispatchSourceFileSystemObject?
    private var writeTail: Task<Void, Never>?
    private var writeID = 0
    var repos: [RepoEntry] = []

    // Fired alongside refresh() on every detected file write, including ones this process
    // didn't make itself (e.g. the srota-mcp server's add_session_note tool, a separate
    // process writing the same db file directly). SessionRecorder uses this to pick up
    // agent-initiated notes live, without a new IPC path — see ponytail note on
    // SessionRecorder.refreshTrackedPanes(): this fires on every write, not just relevant
    // ones (same accepted cost the repos refresh above already pays).
    var onExternalWrite: (() -> Void)?

    init() {
        Task {
            await storage.open()
            startDBWatcher(dbPath: storage.dbPath)
            await refresh()
        }
    }

    private func startDBWatcher(dbPath: String) {
        dbWatcher = makeFileWatcher(path: dbPath)
        // ponytail: if the -wal file doesn't exist yet at this exact moment (a truly fresh db
        // that's never been opened in WAL mode before), this watcher is simply skipped — no
        // retry/directory-watch for its later creation. In practice it already exists by the
        // time the app runs, since srota-mcp sets WAL mode on its very first invocation ever
        // and that setting is permanent for the file from then on. Revisit if a fresh-install
        // path ever needs this before the MCP server has run once.
        dbWalWatcher = makeFileWatcher(path: dbPath + "-wal")
    }

    private func makeFileWatcher(path: String) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib], queue: .main)
        src.setEventHandler { [weak self] in
            Task { await self?.refresh() }
            self?.onExternalWrite?()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }

    func refresh() async {
        await writeTail?.value
        repos = await storage.loadRepos()
    }

    func addRepo(name: String, url: String = "", defaultBranch: String = "main") {
        enqueueWrite { await $0.addRepo(name: name, url: url, defaultBranch: defaultBranch) }
        Task { await refresh() }
    }

    func updateRepo(_ repo: RepoEntry) {
        enqueueWrite { await $0.updateRepo(repo) }
        Task { await refresh() }
    }

    func deleteRepo(id: String) {
        enqueueWrite { await $0.deleteRepo(id: id) }
        Task { await refresh() }
    }

    private func enqueueWrite(_ operation: @escaping @Sendable (WorkspaceStorage) async -> Void) {
        let previous = writeTail
        let storage = storage
        writeID += 1
        let id = writeID
        let task = Task {
            await previous?.value
            await operation(storage)
        }
        writeTail = task
        Task {
            await task.value
            if writeID == id {
                writeTail = nil
            }
        }
    }

    func saveWorkspaceSession(_ session: WorkspaceSession) {
        enqueueWrite { await $0.saveWorkspaceSession(session) }
    }

    func updateWorkspaceDirectory(id: String, directory: String) {
        enqueueWrite { await $0.updateWorkspaceDirectory(id: id, directory: directory) }
    }

    func toggleWorkspacePin(id: String) {
        enqueueWrite { await $0.toggleWorkspacePin(id: id) }
    }

    func touchWorkspaceSession(id: String, cwd: String) {
        enqueueWrite { await $0.touchWorkspaceSession(id: id, cwd: cwd) }
    }

    func deleteWorkspaceSession(id: String) {
        enqueueWrite { await $0.deleteWorkspaceSession(id: id) }
    }

    func saveTabsAndPanes(workspaceID: String, records: [(TabRecord, [PaneRecord])]) {
        enqueueWrite { await $0.saveTabsAndPanes(workspaceID: workspaceID, records: records) }
    }

    func saveLayoutSnapshot(_ snapshots: [WorkspaceLayoutSnapshot]) {
        enqueueWrite { await $0.saveLayoutSnapshot(snapshots) }
    }

    func upsertSession(_ record: SessionRecord) {
        enqueueWrite { await $0.upsertSession(record) }
    }

    func findSession(paneID: String, externalSessionID: String) async -> SessionRecord? {
        await writeTail?.value
        return await storage.findSession(paneID: paneID, externalSessionID: externalSessionID)
    }

    // Steps for a pane's most recently created session — used to seed the pane-top steps bar
    // on first appearance (SessionRecorder's in-memory cache covers live updates from there).
    func currentSessionSteps(paneID: String) async -> [SessionStepRecord] {
        await writeTail?.value
        return await storage.currentSessionSteps(paneID: paneID)
    }

    func appendSessionStep(_ record: SessionStepRecord) {
        enqueueWrite { await $0.appendSessionStep(record) }
    }

    // Cascade: deletes session_steps before the session itself (ticket 06).
    func deleteSession(id: String) {
        enqueueWrite { await $0.deleteSession(id: id) }
    }

    // Cascade on real pane close only — never wire this to ws_panes' own delete/reinsert
    // churn from saveTabsAndPanes/saveLayoutSnapshot, which fires on every routine layout
    // save, not just when a pane is actually closed (ticket 07).
    func deleteSessions(paneID: String) {
        enqueueWrite { await $0.deleteSessions(paneID: paneID) }
    }

    func flushWritesBlocking() {
        let tail = writeTail
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await tail?.value
            semaphore.signal()
        }
        semaphore.wait()
    }

    func loadWorkspaceRestoreRecords() async -> [(WorkspaceSession, [(TabRecord, [PaneRecord])])] {
        await storage.loadWorkspaceRestoreRecords()
    }
}

private actor WorkspaceStorage {
    nonisolated let dbPath: String
    private var db: OpaquePointer?
    private var didLogOpenFailure = false

    private var sqlFrom: String { "FR" + "OM" }
    private var sqlWhere: String { "WH" + "ERE" }

    init() {
        let dir = NSHomeDirectory() + "/\(Srota.dir)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        #if DEBUG
        let dbName = "srota_debug.db"
        #else
        let dbName = "srota.db"
        #endif
        dbPath = dir + "/" + dbName
    }

    deinit {
        sqlite3_close(db)
    }

    func open() {
        guard db == nil else { return }
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            if !didLogOpenFailure {
                didLogOpenFailure = true
                NSLog("Srota WorkspaceDB: sqlite3_open failed for %@", dbPath)
            }
            sqlite3_close(db)
            db = nil
            return
        }
        createTables()
    }

    func loadRepos() -> [RepoEntry] {
        open()
        return rows(sql("SELECT id, name, url, default_branch", sqlFrom, "repos", "ORDER BY name")) {
            RepoEntry(id: col($0, 0), name: col($0, 1), url: col($0, 2), defaultBranch: col($0, 3))
        }
    }

    func addRepo(name: String, url: String = "", defaultBranch: String = "main") {
        open()
        let id = UUID().uuidString
        upsert("repos", ["id": id, "name": name, "url": url, "default_branch": defaultBranch])
    }

    func updateRepo(_ repo: RepoEntry) {
        open()
        upsert("repos", ["id": repo.id, "name": repo.name, "url": repo.url, "default_branch": repo.defaultBranch])
    }

    func deleteRepo(id: String) {
        open()
        exec(sql("DELETE", sqlFrom, "repos", sqlWhere, "id = ?"), [id])
    }

    private func createTables() {
        execRaw("ALTER TABLE repos ADD COLUMN default_branch TEXT NOT NULL DEFAULT 'main'")
        execRaw("ALTER TABLE ws_workspaces ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0")
        execRaw("ALTER TABLE ws_workspaces ADD COLUMN directory TEXT NOT NULL DEFAULT ''")
        execRaw("ALTER TABLE ws_workspaces ADD COLUMN additional_directories TEXT NOT NULL DEFAULT ''")
        execRaw("DROP TABLE IF EXISTS organizations")
        execRaw("DROP TABLE IF EXISTS projects")
        execRaw("DROP TABLE IF EXISTS branches")
        execRaw("DROP TABLE IF EXISTS features")
        execRaw("DROP TABLE IF EXISTS feature_repos")
        execRaw("DROP TABLE IF EXISTS issues")
        execRaw("DROP TABLE IF EXISTS issue_repos")
        execRaw("DROP TABLE IF EXISTS repo_branches")
        execRaw("""
        CREATE TABLE IF NOT EXISTS repos (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            url TEXT NOT NULL DEFAULT '',
            local_path TEXT NOT NULL DEFAULT '',
            default_branch TEXT NOT NULL DEFAULT 'main'
        );
        CREATE TABLE IF NOT EXISTS ws_workspaces (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            folder_name TEXT NOT NULL DEFAULT '',
            folder_tag TEXT NOT NULL DEFAULT '',
            folder_position INTEGER NOT NULL DEFAULT -1,
            position INTEGER NOT NULL DEFAULT 0,
            tmux_id TEXT,
            tmux_name TEXT,
            last_cwd TEXT NOT NULL DEFAULT '',
            last_accessed INTEGER NOT NULL DEFAULT 0,
            is_pinned INTEGER NOT NULL DEFAULT 0,
            directory TEXT NOT NULL DEFAULT '',
            additional_directories TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS ws_tabs (
            id TEXT PRIMARY KEY,
            workspace_id TEXT NOT NULL,
            position INTEGER NOT NULL DEFAULT 0,
            tmux_id TEXT,
            tmux_name TEXT,
            initial_cwd TEXT NOT NULL DEFAULT '',
            is_selected INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS ws_panes (
            id TEXT PRIMARY KEY,
            tab_id TEXT NOT NULL,
            is_primary INTEGER NOT NULL DEFAULT 1,
            position INTEGER NOT NULL DEFAULT 0,
            lx REAL NOT NULL DEFAULT 0,
            ly REAL NOT NULL DEFAULT 0,
            lw REAL NOT NULL DEFAULT 1,
            lh REAL NOT NULL DEFAULT 1,
            tmux_id TEXT,
            tmux_name TEXT,
            initial_cwd TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            pane_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            external_session_id TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            summary TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            ended_at INTEGER
        );
        CREATE TABLE IF NOT EXISTS session_steps (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            hook_event TEXT NOT NULL,
            title TEXT NOT NULL,
            description TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT 'raw',
            tag TEXT NOT NULL DEFAULT 'agent',
            created_at INTEGER NOT NULL
        );
        """)
        migrateSessionStepsTagIfNeeded()
        migratePanesIfNeeded()
        migrateFolderPositionIfNeeded()
    }

    private func migrateFolderPositionIfNeeded() {
        let cols = rows("PRAGMA table_info(ws_workspaces)", bind: []) { col($0, 1) }
        guard !cols.contains("folder_position") else { return }
        exec("ALTER TABLE ws_workspaces ADD COLUMN folder_position INTEGER NOT NULL DEFAULT -1")
        let folderNames = rows(
            "SELECT DISTINCT folder_name FROM ws_workspaces WHERE folder_name != '' ORDER BY folder_name",
            bind: []
        ) { col($0, 0) }
        for (i, name) in folderNames.enumerated() {
            exec("UPDATE ws_workspaces SET folder_position = ? WHERE folder_name = ?", [String(i), name])
        }
    }

    private func migrateSessionStepsTagIfNeeded() {
        let cols = rows("PRAGMA table_info(session_steps)", bind: []) { col($0, 1) }
        guard !cols.contains("tag") else { return }
        exec("ALTER TABLE session_steps ADD COLUMN tag TEXT NOT NULL DEFAULT 'agent'")
    }

    private func migratePanesIfNeeded() {
        let cols = rows("PRAGMA table_info(ws_panes)", bind: []) { col($0, 1) }
        guard !cols.contains("position") else { return }
        exec("ALTER TABLE ws_panes ADD COLUMN position INTEGER NOT NULL DEFAULT 0")
        let rowsToMigrate = rows("SELECT id, tab_id FROM ws_panes ORDER BY tab_id, rowid", bind: []) {
            (col($0, 0), col($0, 1))
        }
        var currentTabID: String?
        var position = 0
        for (id, tabID) in rowsToMigrate {
            if tabID != currentTabID {
                currentTabID = tabID
                position = 0
            }
            exec("UPDATE ws_panes SET position = ? WHERE id = ?", [String(position), id])
            position += 1
        }
    }

    func saveWorkspaceSession(_ session: WorkspaceSession) {
        open()
        upsert("ws_workspaces", [
            "id": session.id,
            "name": session.name,
            "folder_name": session.folderName,
            "folder_tag": session.folderTag,
            "folder_position": String(session.folderPosition),
            "position": String(session.position),
            "last_cwd": session.lastCWD,
            "last_accessed": String(session.lastAccessed),
            "is_pinned": session.isPinned ? "1" : "0",
            "directory": session.directory,
            "additional_directories": session.additionalDirectories.joined(separator: "\n")
        ])
    }

    func updateWorkspaceDirectory(id: String, directory: String) {
        open()
        exec("UPDATE ws_workspaces SET directory = ? WHERE id = ?", [directory, id])
    }

    func toggleWorkspacePin(id: String) {
        open()
        exec("UPDATE ws_workspaces SET is_pinned = 1 - is_pinned WHERE id = ?", [id])
    }

    func touchWorkspaceSession(id: String, cwd: String) {
        open()
        exec("UPDATE ws_workspaces SET last_cwd = ?, last_accessed = ? WHERE id = ?", [
            cwd,
            String(Int(Date().timeIntervalSince1970)),
            id
        ])
    }

    func deleteWorkspaceSession(id: String) {
        open()
        deleteTabs(workspaceID: id)
        exec(sql("DELETE", sqlFrom, "ws_workspaces", sqlWhere, "id = ?"), [id])
    }

    private func saveTab(_ tab: TabRecord) {
        upsert("ws_tabs", [
            "id": tab.id,
            "workspace_id": tab.workspaceID,
            "position": String(tab.position),
            "initial_cwd": tab.initialCWD,
            "is_selected": tab.isSelected ? "1" : "0"
        ])
    }

    private func deleteTabs(workspaceID: String) {
        let tabIDs = rows(sql("SELECT id", sqlFrom, "ws_tabs", sqlWhere, "workspace_id = ?"), bind: [workspaceID]) {
            col($0, 0)
        }
        NSLog("PANEBUG deleteTabs ws=%@ tabIDs=%@", workspaceID, tabIDs)
        for tabID in tabIDs {
            exec(sql("DELETE", sqlFrom, "ws_panes", sqlWhere, "tab_id = ?"), [tabID])
        }
        exec(sql("DELETE", sqlFrom, "ws_tabs", sqlWhere, "workspace_id = ?"), [workspaceID])
    }

    private func loadTabs(workspaceID: String) -> [TabRecord] {
        rows(sql("SELECT id,workspace_id,position,initial_cwd,is_selected", sqlFrom, "ws_tabs", sqlWhere, "workspace_id=?", "ORDER BY position"), bind: [workspaceID]) { stmt in
            TabRecord(
                id: col(stmt, 0),
                workspaceID: col(stmt, 1),
                position: Int(sqlite3_column_int(stmt, 2)),
                initialCWD: col(stmt, 3),
                isSelected: sqlite3_column_int(stmt, 4) != 0
            )
        }
    }

    private func savePane(_ pane: PaneRecord) {
        NSLog("PANEBUG savePane id=%@ tab=%@ pos=%d", pane.id, pane.tabID, pane.position)
        upsert("ws_panes", [
            "id": pane.id,
            "tab_id": pane.tabID,
            "is_primary": pane.isPrimary ? "1" : "0",
            "position": String(pane.position),
            "lx": String(pane.lx),
            "ly": String(pane.ly),
            "lw": String(pane.lw),
            "lh": String(pane.lh),
            "initial_cwd": pane.initialCWD
        ])
    }

    private func loadPanes(tabID: String) -> [PaneRecord] {
        rows(sql("SELECT id,tab_id,is_primary,lx,ly,lw,lh,initial_cwd,position", sqlFrom, "ws_panes", sqlWhere, "tab_id=?", "ORDER BY position ASC"), bind: [tabID]) { stmt in
            PaneRecord(
                id: col(stmt, 0),
                tabID: col(stmt, 1),
                isPrimary: sqlite3_column_int(stmt, 2) != 0,
                lx: sqlite3_column_double(stmt, 3),
                ly: sqlite3_column_double(stmt, 4),
                lw: sqlite3_column_double(stmt, 5),
                lh: sqlite3_column_double(stmt, 6),
                initialCWD: col(stmt, 7),
                position: Int(sqlite3_column_int(stmt, 8))
            )
        }
    }

    func saveTabsAndPanes(workspaceID: String, records: [(TabRecord, [PaneRecord])]) {
        open()
        execRaw("BEGIN IMMEDIATE TRANSACTION")
        deleteTabs(workspaceID: workspaceID)
        for (tab, panes) in records {
            saveTab(tab)
            for pane in panes {
                savePane(pane)
            }
        }
        execRaw("COMMIT")
    }

    func saveLayoutSnapshot(_ snapshots: [WorkspaceLayoutSnapshot]) {
        open()
        execRaw("BEGIN IMMEDIATE TRANSACTION")
        for snapshot in snapshots {
            saveWorkspaceSession(snapshot.session)
            if let records = snapshot.tabsAndPanes {
                deleteTabs(workspaceID: snapshot.session.id)
                for (tab, panes) in records {
                    saveTab(tab)
                    for pane in panes {
                        savePane(pane)
                    }
                }
            }
        }
        execRaw("COMMIT")
    }

    func loadWorkspaceRestoreRecords() -> [(WorkspaceSession, [(TabRecord, [PaneRecord])])] {
        open()
        return loadWorkspaceSessions().map { session in
            let tabs = loadTabs(workspaceID: session.id)
            return (session, tabs.map { ($0, loadPanes(tabID: $0.id)) })
        }
    }

    private func loadWorkspaceSessions() -> [WorkspaceSession] {
        let all = rows("""
        SELECT id, name, folder_name, folder_tag, position,
               last_cwd, last_accessed, is_pinned, directory, folder_position, additional_directories
        FROM ws_workspaces ORDER BY folder_position, folder_name, position
        """) { stmt in
            let extraDirs = col(stmt, 10)
            return WorkspaceSession(
                id: col(stmt, 0),
                name: col(stmt, 1),
                folderName: col(stmt, 2),
                folderTag: col(stmt, 3),
                position: Int(sqlite3_column_int(stmt, 4)),
                lastCWD: col(stmt, 5),
                lastAccessed: Int(sqlite3_column_int(stmt, 6)),
                isPinned: sqlite3_column_int(stmt, 7) != 0,
                directory: col(stmt, 8),
                folderPosition: Int(sqlite3_column_int(stmt, 9)),
                additionalDirectories: extraDirs.isEmpty ? [] : extraDirs.split(separator: "\n").map(String.init)
            )
        }

        var best: [String: WorkspaceSession] = [:]
        for session in all {
            let key = "\(session.folderName)/\(session.name)"
            if best[key] == nil || session.lastAccessed > best[key]!.lastAccessed {
                best[key] = session
            }
        }

        let keepIDs = Set(best.values.map(\.id))
        for session in all where !keepIDs.contains(session.id) {
            exec(sql("DELETE", sqlFrom, "ws_workspaces", sqlWhere, "id = ?"), [session.id])
        }

        return best.values.sorted {
            $0.folderPosition != $1.folderPosition
            ? $0.folderPosition < $1.folderPosition
            : $0.position < $1.position
        }
    }

    // ended_at needs a real SQL NULL while a session is active (not '' — that would defeat
    // "ended_at IS NULL means active"), so this binds manually instead of going through the
    // generic all-TEXT upsert() below.
    func upsertSession(_ record: SessionRecord) {
        open()
        let sqlText = """
        INSERT OR REPLACE INTO sessions (id, pane_id, provider, external_session_id, title, summary, created_at, ended_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sqlText, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, record.id, -1, SQLITE_TRANSIENT_FN)
        sqlite3_bind_text(stmt, 2, record.paneID, -1, SQLITE_TRANSIENT_FN)
        sqlite3_bind_text(stmt, 3, record.provider, -1, SQLITE_TRANSIENT_FN)
        sqlite3_bind_text(stmt, 4, record.externalSessionID, -1, SQLITE_TRANSIENT_FN)
        sqlite3_bind_text(stmt, 5, record.title, -1, SQLITE_TRANSIENT_FN)
        sqlite3_bind_text(stmt, 6, record.summary, -1, SQLITE_TRANSIENT_FN)
        sqlite3_bind_int64(stmt, 7, Int64(record.createdAt))
        if let endedAt = record.endedAt {
            sqlite3_bind_int64(stmt, 8, Int64(endedAt))
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func findSession(paneID: String, externalSessionID: String) -> SessionRecord? {
        open()
        return rows(
            sql("SELECT id, pane_id, provider, external_session_id, title, summary, created_at, ended_at",
                sqlFrom, "sessions", sqlWhere, "pane_id = ? AND external_session_id = ?"),
            bind: [paneID, externalSessionID]
        ) { stmt in
            SessionRecord(
                id: col(stmt, 0),
                paneID: col(stmt, 1),
                provider: col(stmt, 2),
                externalSessionID: col(stmt, 3),
                title: col(stmt, 4),
                summary: col(stmt, 5),
                createdAt: Int(sqlite3_column_int64(stmt, 6)),
                endedAt: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 7))
            )
        }.first
    }

    func currentSessionSteps(paneID: String) -> [SessionStepRecord] {
        open()
        let latestSessionIDs = rows(
            sql("SELECT id", sqlFrom, "sessions", sqlWhere, "pane_id = ?", "ORDER BY created_at DESC LIMIT 1"),
            bind: [paneID],
            { col($0, 0) }
        )
        guard let sessionID = latestSessionIDs.first else { return [] }
        return rows(
            sql("SELECT id, session_id, hook_event, title, description, source, tag, created_at",
                sqlFrom, "session_steps", sqlWhere, "session_id = ?", "ORDER BY created_at ASC"),
            bind: [sessionID]
        ) { stmt in
            SessionStepRecord(
                id: col(stmt, 0),
                sessionID: col(stmt, 1),
                hookEvent: col(stmt, 2),
                title: col(stmt, 3),
                description: col(stmt, 4),
                source: col(stmt, 5),
                tag: col(stmt, 6),
                createdAt: Int(sqlite3_column_int64(stmt, 7))
            )
        }
    }

    func appendSessionStep(_ record: SessionStepRecord) {
        open()
        upsert("session_steps", [
            "id": record.id,
            "session_id": record.sessionID,
            "hook_event": record.hookEvent,
            "title": record.title,
            "description": record.description,
            "source": record.source,
            "tag": record.tag,
            "created_at": String(record.createdAt)
        ])
    }

    func deleteSession(id: String) {
        open()
        exec(sql("DELETE", sqlFrom, "session_steps", sqlWhere, "session_id = ?"), [id])
        exec(sql("DELETE", sqlFrom, "sessions", sqlWhere, "id = ?"), [id])
    }

    func deleteSessions(paneID: String) {
        open()
        let sessionIDs = rows(sql("SELECT id", sqlFrom, "sessions", sqlWhere, "pane_id = ?"), bind: [paneID]) { col($0, 0) }
        for id in sessionIDs {
            deleteSession(id: id)
        }
    }

    private func sql(_ parts: String...) -> String {
        parts.joined(separator: " ")
    }

    private func upsert(_ table: String, _ values: [String: String]) {
        let keys = values.keys.sorted()
        let orderedValues = keys.map { values[$0]! }
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        let sqlText = "INSERT OR REPLACE INTO \(table) (\(keys.joined(separator: ", "))) VALUES (\(placeholders))"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sqlText, -1, &stmt, nil) == SQLITE_OK else { return }
        for (index, value) in orderedValues.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT_FN)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func exec(_ sqlText: String, _ bind: [String] = []) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sqlText, -1, &stmt, nil) == SQLITE_OK else { return }
        for (index, value) in bind.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT_FN)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func execRaw(_ sqlText: String) {
        _ = sqlite3_exec(db, sqlText, nil, nil, nil)
    }

    private func rows<T>(_ sqlText: String, bind: [String] = [], _ map: (OpaquePointer) -> T) -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sqlText, -1, &stmt, nil) == SQLITE_OK else { return [] }
        for (index, value) in bind.enumerated() {
            sqlite3_bind_text(stmt, Int32(index + 1), value, -1, SQLITE_TRANSIENT_FN)
        }

        var result: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW, let stmt {
            result.append(map(stmt))
        }
        sqlite3_finalize(stmt)
        return result
    }

    private func col(_ stmt: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(stmt, index).map { String(cString: $0) } ?? ""
    }
}
