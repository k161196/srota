import Foundation
import Observation
import SQLite3

// ponytail: raw sqlite3 C API — no dep; add SQLite.swift if query complexity grows

private let SQLITE_TRANSIENT_FN = unsafeBitCast(-1 as Int, to: sqlite3_destructor_type.self)

private final class DBHandle {
    var ptr: OpaquePointer?
    deinit { sqlite3_close(ptr) }
}

// MARK: - Session model (sidebar workspace tree, persisted across restarts)

struct WorkspaceSession: Identifiable {
    var id: String
    var name: String
    var folderName: String
    var folderTag: String
    var position: Int
    var tmuxID: String?
    var tmuxName: String?
    var lastCWD: String
    var lastAccessed: Int
}

struct TabRecord: Identifiable {
    var id: String
    var workspaceID: String
    var position: Int
    var tmuxID: String?
    var tmuxName: String?
    var initialCWD: String
    var isSelected: Bool
}

struct PaneRecord: Identifiable {
    var id: String
    var tabID: String
    var isPrimary: Bool
    var lx, ly, lw, lh: Double   // fractional layout (0–1)
    var tmuxID: String?
    var tmuxName: String?
    var initialCWD: String
}

// MARK: - Models

struct Organization: Identifiable, Hashable {
    var id, name, path: String
}
struct Project: Identifiable, Hashable {
    var id, orgID, name, path, description: String
}
struct Feature: Identifiable, Hashable {
    var id, projectID, name, description: String
}
struct RepoEntry: Identifiable, Hashable {
    var id, name, url, localPath: String
    var featureID: String
}
struct Issue: Identifiable, Hashable {
    var id, title, body, status: String
    var orgID: String
    var featureID: String
}

// MARK: - DB

@Observable @MainActor
final class WorkspaceDB {
    private let handle = DBHandle()
    private var db: OpaquePointer? { handle.ptr }

    var organizations: [Organization] = []
    var projects:      [Project]      = []
    var features:      [Feature]      = []
    var repos:         [RepoEntry]    = []
    var issues:        [Issue]        = []

    init() {
        let dir = NSHomeDirectory() + "/.srota"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard sqlite3_open(dir + "/srota.db", &handle.ptr) == SQLITE_OK else { return }
        createTables()
        refresh()
    }

    // MARK: - Scan (from base dir folder structure)

    func scan(baseDir: String) {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: baseDir)
        let orgsRoot = base.appendingPathComponent("organizations")
        guard let orgDirs = dirs(at: orgsRoot, fm: fm) else { return }

        for orgURL in orgDirs {
            let orgName = orgURL.lastPathComponent
            upsert("organizations", ["id": orgName, "name": orgName, "path": orgURL.path])

            let projRoot = orgURL.appendingPathComponent("projects")
            guard let projDirs = dirs(at: projRoot, fm: fm) else { continue }

            for projURL in projDirs {
                let projName = projURL.lastPathComponent
                let projID = "\(orgName)/\(projName)"
                upsert("projects", ["id": projID, "org_id": orgName, "name": projName, "path": projURL.path, "description": ""])

                let branchRoot = projURL.appendingPathComponent("branches")
                guard let branchDirs = dirs(at: branchRoot, fm: fm) else { continue }

                for branchURL in branchDirs {
                    let branchName = branchURL.lastPathComponent
                    let branchID = "\(projID)/\(branchName)"
                    upsert("branches", ["id": branchID, "project_id": projID, "name": branchName, "path": branchURL.path])
                }
            }
        }
        refresh()
    }

    // MARK: - CRUD: Organizations

    func addOrganization(name: String, path: String = "") {
        upsert("organizations", ["id": UUID().uuidString, "name": name, "path": path])
        refresh()
    }
    func updateOrganization(_ org: Organization) {
        upsert("organizations", ["id": org.id, "name": org.name, "path": org.path])
        refresh()
    }
    func deleteOrganization(id: String) {
        exec("DELETE FROM organizations WHERE id = ?", [id])
        refresh()
    }

    // MARK: - CRUD: Projects

    func addProject(name: String, orgID: String, path: String = "") {
        upsert("projects", ["id": UUID().uuidString, "org_id": orgID, "name": name, "path": path, "description": ""])
        refresh()
    }
    func updateProject(_ p: Project) {
        upsert("projects", ["id": p.id, "org_id": p.orgID, "name": p.name, "path": p.path, "description": p.description])
        refresh()
    }
    func deleteProject(id: String) {
        exec("DELETE FROM projects WHERE id = ?", [id])
        refresh()
    }

    // MARK: - CRUD: Features

    func addFeature(name: String, projectID: String, description: String = "") {
        upsert("features", ["id": UUID().uuidString, "project_id": projectID, "name": name, "description": description])
        refresh()
    }
    func updateFeature(_ f: Feature) {
        upsert("features", ["id": f.id, "project_id": f.projectID, "name": f.name, "description": f.description])
        refresh()
    }
    func deleteFeature(id: String) {
        exec("DELETE FROM features WHERE id = ?", [id])
        refresh()
    }

    // MARK: - CRUD: Repos

    func addRepo(name: String, url: String = "", localPath: String = "", featureID: String = "") {
        upsert("repos", ["id": UUID().uuidString, "name": name, "url": url, "local_path": localPath, "feature_id": featureID])
        refresh()
    }
    func updateRepo(_ r: RepoEntry) {
        upsert("repos", ["id": r.id, "name": r.name, "url": r.url, "local_path": r.localPath, "feature_id": r.featureID])
        refresh()
    }
    func deleteRepo(id: String) {
        exec("DELETE FROM repos WHERE id = ?", [id])
        refresh()
    }

    // MARK: - CRUD: Issues

    func addIssue(title: String, body: String = "", status: String = "open", orgID: String = "", featureID: String = "") {
        upsert("issues", ["id": UUID().uuidString, "title": title, "body": body, "status": status, "org_id": orgID, "feature_id": featureID])
        refresh()
    }
    func updateIssue(_ i: Issue) {
        upsert("issues", ["id": i.id, "title": i.title, "body": i.body, "status": i.status, "org_id": i.orgID, "feature_id": i.featureID])
        refresh()
    }
    func deleteIssue(id: String) {
        exec("DELETE FROM issues WHERE id = ?", [id])
        refresh()
    }

    func branches(projectID: String) -> [(id: String, name: String, path: String)] {
        rows("SELECT id, name, path FROM branches WHERE project_id = ? ORDER BY name",
             bind: [projectID]) {
            (id: col($0, 0), name: col($0, 1), path: col($0, 2))
        }
    }

    // MARK: - Refresh

    func refresh() {
        organizations = rows("SELECT id, name, path FROM organizations ORDER BY name") {
            Organization(id: col($0, 0), name: col($0, 1), path: col($0, 2))
        }
        projects = rows("SELECT id, org_id, name, path, description FROM projects ORDER BY name") {
            Project(id: col($0, 0), orgID: col($0, 1), name: col($0, 2), path: col($0, 3), description: col($0, 4))
        }
        features = rows("SELECT id, project_id, name, description FROM features ORDER BY name") {
            Feature(id: col($0, 0), projectID: col($0, 1), name: col($0, 2), description: col($0, 3))
        }
        repos = rows("SELECT id, name, url, local_path, feature_id FROM repos ORDER BY name") {
            RepoEntry(id: col($0, 0), name: col($0, 1), url: col($0, 2), localPath: col($0, 3), featureID: col($0, 4))
        }
        issues = rows("SELECT id, title, body, status, org_id, feature_id FROM issues ORDER BY title") {
            Issue(id: col($0, 0), title: col($0, 1), body: col($0, 2), status: col($0, 3), orgID: col($0, 4), featureID: col($0, 5))
        }
    }

    // MARK: - Private

    private func createTables() {
        // ALTER TABLE runs separately — fails silently if column exists; must not abort the CREATE TABLE batch
        execRaw("ALTER TABLE projects ADD COLUMN description TEXT NOT NULL DEFAULT ''")
        execRaw("""
            CREATE TABLE IF NOT EXISTS organizations
                (id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL DEFAULT '');
            CREATE TABLE IF NOT EXISTS projects
                (id TEXT PRIMARY KEY, org_id TEXT NOT NULL, name TEXT NOT NULL, path TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '');
            CREATE TABLE IF NOT EXISTS branches
                (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, name TEXT NOT NULL, path TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS features
                (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '');
            CREATE TABLE IF NOT EXISTS repos
                (id TEXT PRIMARY KEY, name TEXT NOT NULL, url TEXT NOT NULL DEFAULT '',
                 local_path TEXT NOT NULL DEFAULT '', feature_id TEXT NOT NULL DEFAULT '');
            CREATE TABLE IF NOT EXISTS issues
                (id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL DEFAULT '',
                 status TEXT NOT NULL DEFAULT 'open', org_id TEXT NOT NULL DEFAULT '',
                 feature_id TEXT NOT NULL DEFAULT '');
            CREATE TABLE IF NOT EXISTS ws_workspaces (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                folder_name TEXT NOT NULL DEFAULT '',
                folder_tag TEXT NOT NULL DEFAULT '',
                position INTEGER NOT NULL DEFAULT 0,
                tmux_id TEXT,
                tmux_name TEXT,
                last_cwd TEXT NOT NULL DEFAULT '',
                last_accessed INTEGER NOT NULL DEFAULT 0
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
                lx REAL NOT NULL DEFAULT 0,
                ly REAL NOT NULL DEFAULT 0,
                lw REAL NOT NULL DEFAULT 1,
                lh REAL NOT NULL DEFAULT 1,
                tmux_id TEXT,
                tmux_name TEXT,
                initial_cwd TEXT NOT NULL DEFAULT ''
            );
        """)
    }

    // MARK: - Workspace Session CRUD

    func saveWorkspaceSession(_ s: WorkspaceSession) {
        upsert("ws_workspaces", [
            "id": s.id, "name": s.name,
            "folder_name": s.folderName, "folder_tag": s.folderTag,
            "position": String(s.position),
            "tmux_id": s.tmuxID ?? "", "tmux_name": s.tmuxName ?? "",
            "last_cwd": s.lastCWD,
            "last_accessed": String(s.lastAccessed)
        ])
    }

    func touchWorkspaceSession(id: String, cwd: String) {
        exec("UPDATE ws_workspaces SET last_cwd = ?, last_accessed = ? WHERE id = ?",
             [cwd, String(Int(Date().timeIntervalSince1970)), id])
    }

    func deleteWorkspaceSession(id: String) {
        exec("DELETE FROM ws_workspaces WHERE id = ?", [id])
    }

    func saveTab(_ t: TabRecord) {
        upsert("ws_tabs", [
            "id": t.id, "workspace_id": t.workspaceID,
            "position": String(t.position),
            "tmux_id": t.tmuxID ?? "", "tmux_name": t.tmuxName ?? "",
            "initial_cwd": t.initialCWD,
            "is_selected": t.isSelected ? "1" : "0"
        ])
    }

    func deleteTabs(workspaceID: String) {
        // cascade: delete panes for all tabs first
        let tabIDs = rows("SELECT id FROM ws_tabs WHERE workspace_id = ?", bind: [workspaceID]) {
            col($0, 0)
        }
        for tid in tabIDs { exec("DELETE FROM ws_panes WHERE tab_id = ?", [tid]) }
        exec("DELETE FROM ws_tabs WHERE workspace_id = ?", [workspaceID])
    }

    func loadTabs(workspaceID: String) -> [TabRecord] {
        rows("SELECT id,workspace_id,position,tmux_id,tmux_name,initial_cwd,is_selected FROM ws_tabs WHERE workspace_id=? ORDER BY position",
             bind: [workspaceID]) { stmt in
            TabRecord(id: col(stmt,0), workspaceID: col(stmt,1),
                      position: Int(sqlite3_column_int(stmt,2)),
                      tmuxID:   col(stmt,3).isEmpty ? nil : col(stmt,3),
                      tmuxName: col(stmt,4).isEmpty ? nil : col(stmt,4),
                      initialCWD: col(stmt,5),
                      isSelected: sqlite3_column_int(stmt,6) != 0)
        }
    }

    func savePane(_ p: PaneRecord) {
        upsert("ws_panes", [
            "id": p.id, "tab_id": p.tabID,
            "is_primary": p.isPrimary ? "1" : "0",
            "lx": String(p.lx), "ly": String(p.ly), "lw": String(p.lw), "lh": String(p.lh),
            "tmux_id": p.tmuxID ?? "", "tmux_name": p.tmuxName ?? "",
            "initial_cwd": p.initialCWD
        ])
    }

    func deletePanes(tabID: String) { exec("DELETE FROM ws_panes WHERE tab_id = ?", [tabID]) }

    func loadPanes(tabID: String) -> [PaneRecord] {
        rows("SELECT id,tab_id,is_primary,lx,ly,lw,lh,tmux_id,tmux_name,initial_cwd FROM ws_panes WHERE tab_id=?",
             bind: [tabID]) { stmt in
            PaneRecord(id: col(stmt,0), tabID: col(stmt,1),
                       isPrimary: sqlite3_column_int(stmt,2) != 0,
                       lx: sqlite3_column_double(stmt,3), ly: sqlite3_column_double(stmt,4),
                       lw: sqlite3_column_double(stmt,5), lh: sqlite3_column_double(stmt,6),
                       tmuxID:   col(stmt,7).isEmpty ? nil : col(stmt,7),
                       tmuxName: col(stmt,8).isEmpty ? nil : col(stmt,8),
                       initialCWD: col(stmt,9))
        }
    }

    func loadWorkspaceSessions() -> [WorkspaceSession] {
        let all = rows("""
            SELECT id, name, folder_name, folder_tag, position,
                   tmux_id, tmux_name, last_cwd, last_accessed
            FROM ws_workspaces ORDER BY folder_name, position
        """) { stmt in
            WorkspaceSession(
                id:           col(stmt, 0),
                name:         col(stmt, 1),
                folderName:   col(stmt, 2),
                folderTag:    col(stmt, 3),
                position:     Int(sqlite3_column_int(stmt, 4)),
                tmuxID:       col(stmt, 5).isEmpty ? nil : col(stmt, 5),
                tmuxName:     col(stmt, 6).isEmpty ? nil : col(stmt, 6),
                lastCWD:      col(stmt, 7),
                lastAccessed: Int(sqlite3_column_int(stmt, 8))
            )
        }
        // dedup: keep newest per (folder, name); delete orphans
        var best: [String: WorkspaceSession] = [:]
        for s in all {
            let key = "\(s.folderName)/\(s.name)"
            if best[key] == nil || s.lastAccessed > best[key]!.lastAccessed { best[key] = s }
        }
        let keepIDs = Set(best.values.map { $0.id })
        for s in all where !keepIDs.contains(s.id) {
            exec("DELETE FROM ws_workspaces WHERE id = ?", [s.id])
        }
        return best.values.sorted { $0.folderName < $1.folderName || ($0.folderName == $1.folderName && $0.position < $1.position) }
    }

    private func dirs(at url: URL, fm: FileManager) -> [URL]? {
        try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    private func upsert(_ table: String, _ kv: [String: String]) {
        let keys = kv.keys.sorted()
        let vals = keys.map { kv[$0]! }
        let ph  = Array(repeating: "?", count: keys.count).joined(separator: ", ")
        let sql = "INSERT OR REPLACE INTO \(table) (\(keys.joined(separator: ", "))) VALUES (\(ph))"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        for (i, v) in vals.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), v, -1, SQLITE_TRANSIENT_FN)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func exec(_ sql: String, _ bind: [String] = []) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        for (i, v) in bind.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), v, -1, SQLITE_TRANSIENT_FN)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func execRaw(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func rows<T>(_ sql: String, bind: [String] = [], map: (OpaquePointer) -> T) -> [T] {
        var result: [T] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        for (i, v) in bind.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), v, -1, SQLITE_TRANSIENT_FN)
        }
        while sqlite3_step(stmt) == SQLITE_ROW { result.append(map(stmt!)) }
        sqlite3_finalize(stmt)
        return result
    }

    private func col(_ stmt: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
    }
}
