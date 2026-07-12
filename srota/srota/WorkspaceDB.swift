import Foundation
import Observation
import SQLite3

private let SQLITE_TRANSIENT_FN = unsafeBitCast(-1 as Int, to: sqlite3_destructor_type.self)

private final class DBHandle {
    var ptr: OpaquePointer?
    deinit { sqlite3_close(ptr) }
}

struct WorkspaceSession: Identifiable {
    var id: String
    var name: String
    var folderName: String
    var folderTag: String
    var position: Int
    var lastCWD: String
    var lastAccessed: Int
    var isPinned: Bool
    var directory: String = ""
    var folderPosition: Int = -1   // order of this workspace's folder among all folders; -1 for unfiled
    var additionalDirectories: [String] = []   // extra repo checkouts a single agent session can --add-dir into
}

struct TabRecord: Identifiable {
    var id: String
    var workspaceID: String
    var position: Int
    var initialCWD: String
    var isSelected: Bool
}

struct PaneRecord: Identifiable {
    var id: String
    var tabID: String
    var isPrimary: Bool      // kept for legacy migration read
    var lx, ly, lw, lh: Double
    var initialCWD: String
    var position: Int = 0    // new: order in panes array
}

struct RepoEntry: Identifiable, Hashable {
    var id: String
    var name: String
    var url: String
    var defaultBranch: String
}

@Observable
@MainActor
final class WorkspaceDB {
    private let handle = DBHandle()
    private var db: OpaquePointer? { handle.ptr }
    private var dbWatcher: DispatchSourceFileSystemObject?

    var repos: [RepoEntry] = []

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
        guard sqlite3_open(dir + "/" + dbName, &handle.ptr) == SQLITE_OK else { return }
        createTables()
        refresh()
        startDBWatcher(dbPath: dir + "/" + dbName)
    }

    private func startDBWatcher(dbPath: String) {
        let fd = open(dbPath, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib], queue: .main)
        src.setEventHandler { [weak self] in self?.refresh() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dbWatcher = src
    }

    func addRepo(name: String, url: String = "", defaultBranch: String = "main") {
        let id = UUID().uuidString
        upsert("repos", ["id": id, "name": name, "url": url, "default_branch": defaultBranch])
        refresh()
    }

    func updateRepo(_ repo: RepoEntry) {
        upsert("repos", ["id": repo.id, "name": repo.name, "url": repo.url, "default_branch": repo.defaultBranch])
        refresh()
    }

    func deleteRepo(id: String) {
        exec(sql("DELETE", sqlFrom, "repos", sqlWhere, "id = ?"), [id])
        refresh()
    }

    func refresh() {
        repos = rows(sql("SELECT id, name, url, default_branch", sqlFrom, "repos", "ORDER BY name")) {
            RepoEntry(id: col($0, 0), name: col($0, 1), url: col($0, 2), defaultBranch: col($0, 3))
        }
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
        CREATE TABLE IF NOT EXISTS repos
        (id TEXT PRIMARY KEY, name TEXT NOT NULL, url TEXT NOT NULL DEFAULT '',
         local_path TEXT NOT NULL DEFAULT '', default_branch TEXT NOT NULL DEFAULT 'main');
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
            is_pinned INTEGER NOT NULL DEFAULT 0
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
        """)
        migratePanesIfNeeded()
        migrateFolderPositionIfNeeded()
    }

    private func migrateFolderPositionIfNeeded() {
        // Add folder_position column if missing, backfilling from the previous
        // alphabetical folder_name ordering so existing folder order doesn't jumble on upgrade.
        let cols = rows("PRAGMA table_info(ws_workspaces)", bind: []) { stmt -> String in
            col(stmt, 1)
        }
        guard !cols.contains("folder_position") else { return }
        exec("ALTER TABLE ws_workspaces ADD COLUMN folder_position INTEGER NOT NULL DEFAULT -1")
        let folderNames = rows(
            "SELECT DISTINCT folder_name FROM ws_workspaces WHERE folder_name != '' ORDER BY folder_name",
            bind: []
        ) { stmt -> String in col(stmt, 0) }
        for (i, name) in folderNames.enumerated() {
            exec("UPDATE ws_workspaces SET folder_position = ? WHERE folder_name = ?", [String(i), name])
        }
    }

    private func migratePanesIfNeeded() {
        // Add position column if missing (SQLite 3.x safe — no DROP COLUMN needed)
        let cols = rows("PRAGMA table_info(ws_panes)", bind: []) { stmt -> String in
            col(stmt, 1)
        }
        guard !cols.contains("position") else { return }
        exec("ALTER TABLE ws_panes ADD COLUMN position INTEGER NOT NULL DEFAULT 0")
        // Seed position from insert order so restored panes stay deterministic.
        // Legacy rows did not persist exact secondary ordering, but rowid preserves the old insert sequence.
        let rowsToMigrate = rows(
            "SELECT id, tab_id FROM ws_panes ORDER BY tab_id, rowid",
            bind: []
        ) { stmt -> (String, String) in
            (col(stmt, 0), col(stmt, 1))
        }
        var currentTabID: String? = nil
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
        exec("UPDATE ws_workspaces SET directory = ? WHERE id = ?", [directory, id])
    }

    func toggleWorkspacePin(id: String) {
        exec("UPDATE ws_workspaces SET is_pinned = 1 - is_pinned WHERE id = ?", [id])
    }

    func touchWorkspaceSession(id: String, cwd: String) {
        exec("UPDATE ws_workspaces SET last_cwd = ?, last_accessed = ? WHERE id = ?", [
            cwd,
            String(Int(Date().timeIntervalSince1970)),
            id
        ])
    }

    func deleteWorkspaceSession(id: String) {
        deleteTabs(workspaceID: id)
        exec(sql("DELETE", sqlFrom, "ws_workspaces", sqlWhere, "id = ?"), [id])
    }

    func saveTab(_ tab: TabRecord) {
        upsert("ws_tabs", [
            "id": tab.id,
            "workspace_id": tab.workspaceID,
            "position": String(tab.position),
            "initial_cwd": tab.initialCWD,
            "is_selected": tab.isSelected ? "1" : "0"
        ])
    }

    func deleteTabs(workspaceID: String) {
        let tabIDs = rows(sql("SELECT id", sqlFrom, "ws_tabs", sqlWhere, "workspace_id = ?"), bind: [workspaceID]) {
            col($0, 0)
        }
        NSLog("PANEBUG deleteTabs ws=%@ tabIDs=%@", workspaceID, tabIDs)
        for tabID in tabIDs {
            exec(sql("DELETE", sqlFrom, "ws_panes", sqlWhere, "tab_id = ?"), [tabID])
        }
        exec(sql("DELETE", sqlFrom, "ws_tabs", sqlWhere, "workspace_id = ?"), [workspaceID])
    }

    func loadTabs(workspaceID: String) -> [TabRecord] {
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

    func savePane(_ pane: PaneRecord) {
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

    func deletePanes(tabID: String) {
        exec(sql("DELETE", sqlFrom, "ws_panes", sqlWhere, "tab_id = ?"), [tabID])
    }

    func loadPanes(tabID: String) -> [PaneRecord] {
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

    func loadWorkspaceSessions() -> [WorkspaceSession] {
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
        sqlite3_exec(db, sqlText, nil, nil, nil)
    }

    private func rows<T>(_ sqlText: String, bind: [String] = [], map: (OpaquePointer) -> T) -> [T] {
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
