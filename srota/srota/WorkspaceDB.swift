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

struct Organization: Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
}

struct Project: Identifiable, Hashable {
    var id: String
    var orgID: String
    var name: String
    var path: String
    var description: String
}

struct Feature: Identifiable, Hashable {
    var id: String
    var projectID: String
    var name: String
    var description: String
    var number: Int
}

struct RepoEntry: Identifiable, Hashable {
    var id: String
    var name: String
    var url: String
    var localPath: String
}

struct FeatureRepo: Identifiable, Hashable {
    var id: String
    var featureID: String
    var repoID: String
    var branch: String
}

struct RepoBranch: Identifiable, Hashable {
    var id: String
    var repoID: String
    var name: String
    var description: String
}

struct Issue: Identifiable, Hashable {
    var id: String
    var title: String
    var body: String
    var status: String
    var orgID: String
    var featureID: String
    var number: Int
}

@Observable
@MainActor
final class WorkspaceDB {
    private let handle = DBHandle()
    private var db: OpaquePointer? { handle.ptr }
    private var scanTask: Task<Void, Never>?
    private var dbWatcher: DispatchSourceFileSystemObject?

    var organizations: [Organization] = []
    var projects: [Project] = []
    var features: [Feature] = []
    var repos: [RepoEntry] = []
    var featureRepos: [FeatureRepo] = []
    var repoBranches: [RepoBranch] = []
    var issues: [Issue] = []

    private struct ScannedBranch {
        let id: String
        let projectID: String
        let name: String
        let path: String
    }

    private struct ScanSnapshot {
        var organizations: [Organization] = []
        var projects: [Project] = []
        var branches: [ScannedBranch] = []
    }

    private var sqlFrom: String { "FR" + "OM" }
    private var sqlWhere: String { "WH" + "ERE" }

    init() {
        let dir = NSHomeDirectory() + "/.srota"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard sqlite3_open(dir + "/srota.db", &handle.ptr) == SQLITE_OK else { return }
        createTables()
        refresh()
        startDBWatcher(dbPath: dir + "/srota.db")
    }

    private func startDBWatcher(dbPath: String) {
        let dir = (dbPath as NSString).deletingLastPathComponent
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.refresh() }
        src.setCancelHandler { close(fd) }
        src.resume()
        dbWatcher = src
    }

    func scan(baseDir: String) {
        scanTask?.cancel()
        scanTask = Task.detached(priority: .utility) { [baseDir] in
            let snapshot = Self.buildScanSnapshot(baseDir: baseDir)
            guard !Task.isCancelled else { return }
            await self.applyScan(snapshot, baseDir: baseDir)
        }
    }

    func addOrganization(name: String, path: String = "") {
        upsert("organizations", ["id": UUID().uuidString, "name": name, "path": path])
        refresh()
    }

    func updateOrganization(_ org: Organization) {
        upsert("organizations", ["id": org.id, "name": org.name, "path": org.path])
        refresh()
    }

    func deleteOrganization(id: String) {
        projects.filter { $0.orgID == id }.forEach { deleteProject(id: $0.id) }
        exec(sql("DELETE", sqlFrom, "organizations", sqlWhere, "id = ?"), [id])
        refresh()
    }

    func addProject(name: String, orgID: String, path: String = "") {
        upsert("projects", [
            "id": UUID().uuidString,
            "org_id": orgID,
            "name": name,
            "path": path,
            "description": ""
        ])
        refresh()
    }

    func updateProject(_ project: Project) {
        upsert("projects", [
            "id": project.id,
            "org_id": project.orgID,
            "name": project.name,
            "path": project.path,
            "description": project.description
        ])
        refresh()
    }

    func deleteProject(id: String) {
        features.filter { $0.projectID == id }.forEach { deleteFeature(id: $0.id) }
        exec(sql("DELETE", sqlFrom, "projects", sqlWhere, "id = ?"), [id])
        refresh()
    }

    func addFeature(name: String, projectID: String, description: String = "") {
        upsert("features", [
            "id": UUID().uuidString,
            "project_id": projectID,
            "name": name,
            "description": description,
            "number": String(nextNumber(in: "features"))
        ])
        refresh()
    }

    func updateFeature(_ feature: Feature) {
        upsert("features", [
            "id": feature.id,
            "project_id": feature.projectID,
            "name": feature.name,
            "description": feature.description,
            "number": String(feature.number)
        ])
        refresh()
    }

    func deleteFeature(id: String) {
        exec(sql("DELETE", sqlFrom, "feature_repos", sqlWhere, "feature_id = ?"), [id])
        exec(sql("UPDATE issues SET feature_id = ''", sqlWhere, "feature_id = ?"), [id])
        exec(sql("DELETE", sqlFrom, "features", sqlWhere, "id = ?"), [id])
        refresh()
    }

    func addRepo(name: String, url: String = "", localPath: String = "") {
        upsert("repos", [
            "id": UUID().uuidString,
            "name": name,
            "url": url,
            "local_path": localPath
        ])
        refresh()
    }

    func updateRepo(_ repo: RepoEntry) {
        upsert("repos", [
            "id": repo.id,
            "name": repo.name,
            "url": repo.url,
            "local_path": repo.localPath
        ])
        refresh()
    }

    func deleteRepo(id: String) {
        exec(sql("DELETE", sqlFrom, "repos", sqlWhere, "id = ?"), [id])
        exec(sql("DELETE", sqlFrom, "feature_repos", sqlWhere, "repo_id = ?"), [id])
        exec(sql("DELETE", sqlFrom, "repo_branches", sqlWhere, "repo_id = ?"), [id])
        refresh()
    }

    func addRepoBranch(repoID: String, name: String, description: String = "") {
        upsert("repo_branches", [
            "id": UUID().uuidString,
            "repo_id": repoID,
            "name": name,
            "description": description
        ])
        refresh()
    }

    func updateRepoBranch(_ branch: RepoBranch) {
        upsert("repo_branches", [
            "id": branch.id,
            "repo_id": branch.repoID,
            "name": branch.name,
            "description": branch.description
        ])
        refresh()
    }

    func deleteRepoBranch(id: String) {
        exec(sql("DELETE", sqlFrom, "repo_branches", sqlWhere, "id = ?"), [id])
        refresh()
    }

    func addFeatureRepo(featureID: String, repoID: String, branch: String) {
        upsert("feature_repos", [
            "id": UUID().uuidString,
            "feature_id": featureID,
            "repo_id": repoID,
            "branch": branch
        ])
        refresh()
    }

    func deleteFeatureRepo(id: String) {
        exec(sql("DELETE", sqlFrom, "feature_repos", sqlWhere, "id = ?"), [id])
        refresh()
    }

    func addIssue(title: String, body: String = "", status: String = "open", orgID: String = "", featureID: String = "") {
        upsert("issues", [
            "id": UUID().uuidString,
            "title": title,
            "body": body,
            "status": status,
            "org_id": orgID,
            "feature_id": featureID,
            "number": String(nextNumber(in: "issues"))
        ])
        refresh()
    }

    func updateIssue(_ issue: Issue) {
        upsert("issues", [
            "id": issue.id,
            "title": issue.title,
            "body": issue.body,
            "status": issue.status,
            "org_id": issue.orgID,
            "feature_id": issue.featureID,
            "number": String(issue.number)
        ])
        refresh()
    }

    func deleteIssue(id: String) {
        exec(sql("DELETE", sqlFrom, "issues", sqlWhere, "id = ?"), [id])
        refresh()
    }

    func branches(projectID: String) -> [(id: String, name: String, path: String)] {
        rows(sql("SELECT id, name, path", sqlFrom, "branches", sqlWhere, "project_id = ?", "ORDER BY name"), bind: [projectID]) {
            (id: col($0, 0), name: col($0, 1), path: col($0, 2))
        }
    }

    func refresh() {
        organizations = rows(sql("SELECT id, name, path", sqlFrom, "organizations", "ORDER BY name")) {
            Organization(id: col($0, 0), name: col($0, 1), path: col($0, 2))
        }
        projects = rows(sql("SELECT id, org_id, name, path, description", sqlFrom, "projects", "ORDER BY name")) {
            Project(id: col($0, 0), orgID: col($0, 1), name: col($0, 2), path: col($0, 3), description: col($0, 4))
        }
        features = rows(sql("SELECT id, project_id, name, description, number", sqlFrom, "features", "ORDER BY number")) {
            Feature(id: col($0, 0), projectID: col($0, 1), name: col($0, 2), description: col($0, 3), number: Int(sqlite3_column_int($0, 4)))
        }
        repos = rows(sql("SELECT id, name, url, local_path", sqlFrom, "repos", "ORDER BY name")) {
            RepoEntry(id: col($0, 0), name: col($0, 1), url: col($0, 2), localPath: col($0, 3))
        }
        featureRepos = rows(sql("SELECT id, feature_id, repo_id, branch", sqlFrom, "feature_repos", "ORDER BY branch")) {
            FeatureRepo(id: col($0, 0), featureID: col($0, 1), repoID: col($0, 2), branch: col($0, 3))
        }
        repoBranches = rows(sql("SELECT id, repo_id, name, description", sqlFrom, "repo_branches", "ORDER BY name")) {
            RepoBranch(id: col($0, 0), repoID: col($0, 1), name: col($0, 2), description: col($0, 3))
        }
        issues = rows(sql("SELECT id, title, body, status, org_id, feature_id, number", sqlFrom, "issues", "ORDER BY number")) {
            Issue(id: col($0, 0), title: col($0, 1), body: col($0, 2), status: col($0, 3), orgID: col($0, 4), featureID: col($0, 5), number: Int(sqlite3_column_int($0, 6)))
        }
    }

    private func createTables() {
        execRaw("ALTER TABLE projects ADD COLUMN description TEXT NOT NULL DEFAULT ''")
        execRaw("ALTER TABLE features ADD COLUMN number INTEGER NOT NULL DEFAULT 0")
        execRaw("ALTER TABLE issues ADD COLUMN number INTEGER NOT NULL DEFAULT 0")
        execRaw("UPDATE features SET number = rowid WHERE number = 0")
        execRaw("UPDATE issues SET number = rowid WHERE number = 0")
        execRaw("""
        CREATE TABLE IF NOT EXISTS organizations
        (id TEXT PRIMARY KEY, name TEXT NOT NULL, path TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS projects
        (id TEXT PRIMARY KEY, org_id TEXT NOT NULL, name TEXT NOT NULL, path TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS branches
        (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, name TEXT NOT NULL, path TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS features
        (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '', number INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS repos
        (id TEXT PRIMARY KEY, name TEXT NOT NULL, url TEXT NOT NULL DEFAULT '',
         local_path TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS feature_repos
        (id TEXT PRIMARY KEY, feature_id TEXT NOT NULL, repo_id TEXT NOT NULL, branch TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS repo_branches
        (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS issues
        (id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL DEFAULT '',
         status TEXT NOT NULL DEFAULT 'open', org_id TEXT NOT NULL DEFAULT '', feature_id TEXT NOT NULL DEFAULT '', number INTEGER NOT NULL DEFAULT 0);
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
        migratePanesIfNeeded()
    }

    private func migratePanesIfNeeded() {
        // Add position column if missing (SQLite 3.x safe — no DROP COLUMN needed)
        let cols = rows("PRAGMA table_info(ws_panes)", bind: []) { stmt -> String in
            col(stmt, 1)
        }
        guard !cols.contains("position") else { return }
        exec("ALTER TABLE ws_panes ADD COLUMN position INTEGER NOT NULL DEFAULT 0")
        // Seed position: primary gets 0, others get 1 (exact order of old secondaries not recoverable)
        exec("UPDATE ws_panes SET position = 0 WHERE is_primary = 1")
        exec("UPDATE ws_panes SET position = 1 WHERE is_primary = 0")
    }

    func saveWorkspaceSession(_ session: WorkspaceSession) {
        upsert("ws_workspaces", [
            "id": session.id,
            "name": session.name,
            "folder_name": session.folderName,
            "folder_tag": session.folderTag,
            "position": String(session.position),
            "last_cwd": session.lastCWD,
            "last_accessed": String(session.lastAccessed)
        ])
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
               last_cwd, last_accessed
        FROM ws_workspaces ORDER BY folder_name, position
        """) { stmt in
            WorkspaceSession(
                id: col(stmt, 0),
                name: col(stmt, 1),
                folderName: col(stmt, 2),
                folderTag: col(stmt, 3),
                position: Int(sqlite3_column_int(stmt, 4)),
                lastCWD: col(stmt, 5),
                lastAccessed: Int(sqlite3_column_int(stmt, 6))
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
            $0.folderName < $1.folderName || ($0.folderName == $1.folderName && $0.position < $1.position)
        }
    }

    nonisolated private static func buildScanSnapshot(baseDir: String) -> ScanSnapshot {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: baseDir)
        let orgsRoot = base.appendingPathComponent("organizations")
        guard let orgDirs = dirs(at: orgsRoot, fm: fm) else { return ScanSnapshot() }

        var snapshot = ScanSnapshot()
        for orgURL in orgDirs {
            let orgName = orgURL.lastPathComponent
            snapshot.organizations.append(Organization(id: orgName, name: orgName, path: orgURL.path))

            let projRoot = orgURL.appendingPathComponent("projects")
            guard let projDirs = dirs(at: projRoot, fm: fm) else { continue }

            for projURL in projDirs {
                let projName = projURL.lastPathComponent
                let projID = "\(orgName)/\(projName)"
                snapshot.projects.append(Project(id: projID, orgID: orgName, name: projName, path: projURL.path, description: ""))

                let branchRoot = projURL.appendingPathComponent("branches")
                guard let branchDirs = dirs(at: branchRoot, fm: fm) else { continue }

                for branchURL in branchDirs {
                    let branchName = branchURL.lastPathComponent
                    snapshot.branches.append(ScannedBranch(
                        id: "\(projID)/\(branchName)",
                        projectID: projID,
                        name: branchName,
                        path: branchURL.path
                    ))
                }
            }
        }
        return snapshot
    }

    private func applyScan(_ snapshot: ScanSnapshot, baseDir: String) {
        // Keep scan additive-only: if a directory disappears, retain the last
        // known DB row instead of pruning history.
        for organization in snapshot.organizations {
            upsert("organizations", [
                "id": organization.id,
                "name": organization.name,
                "path": organization.path
            ])
        }

        for project in snapshot.projects {
            upsert("projects", [
                "id": project.id,
                "org_id": project.orgID,
                "name": project.name,
                "path": project.path,
                "description": ""
            ])
        }

        for branch in snapshot.branches {
            upsert("branches", [
                "id": branch.id,
                "project_id": branch.projectID,
                "name": branch.name,
                "path": branch.path
            ])
        }
        refresh()
    }

    nonisolated private static func dirs(at url: URL, fm: FileManager) -> [URL]? {
        try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    private func sql(_ parts: String...) -> String {
        parts.joined(separator: " ")
    }

    private func nextNumber(in table: String) -> Int {
        let r = rows("SELECT COALESCE(MAX(number), 0) + 1 FROM \(table)") { Int(sqlite3_column_int($0, 0)) }
        return r.first ?? 1
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
