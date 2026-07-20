import SwiftUI
import AppKit

// Aggregated, gh-backed view of Issues/PRs across every repo registered in Srota (WorkspaceDB.repos),
// surfaced as a top-level tab so you don't have to drill into a single repo to see what's open.
// See RepoDetailView (ManagementView.swift) for the single-repo precedent this generalizes from.

// Shared by the Tasks tab's panel, rows, and sheets.
extension Color {
    static let tasksBg        = Color(red: 0.067, green: 0.067, blue: 0.075)
    static let tasksSurface   = Color(red: 0.10,  green: 0.10,  blue: 0.11)
    static let tasksBorder    = Color.white.opacity(0.07)
    static let tasksAccent    = Color(red: 1.0, green: 0.45, blue: 0.15)
    static let tasksLabel     = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let tasksMuted     = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.62)
    static let tasksRow       = Color.white.opacity(0.035)
    static let tasksRowHover  = Color.white.opacity(0.065)
}

private extension Color {
    static let mgBg = tasksBg
    static let mgSurface = tasksSurface
    static let mgBorder = tasksBorder
    static let mgAccent = tasksAccent
    static let mgLabel = tasksLabel
    static let mgMuted = tasksMuted
    static let mgRow = tasksRow
    static let mgRowHover = tasksRowHover
}

// MARK: - GitHub models

struct TaskActor: Decodable, Hashable {
    let login: String
    // GitHub serves a user's avatar off their login with no auth/API call required.
    var avatarURL: URL? { URL(string: "https://github.com/\(login).png?size=64") }
}
struct TaskLabel: Decodable, Hashable { let name: String }
struct TaskReviewRequest: Decodable, Hashable {
    let login: String?
    let name: String?
    var displayName: String { login ?? name ?? "team" }
    // Teams (no `login`) have no user avatar to fetch.
    var avatarURL: URL? { login.flatMap { URL(string: "https://github.com/\($0).png?size=64") } }
}
// statusCheckRollup mixes CheckRun (status/conclusion) and legacy StatusContext (state) shapes
// from the GitHub API — all optional since either shape can lack the other's fields; a strict,
// non-optional decode would fail the whole array (and thus the whole issue/PR fetch for that
// repo) on one entry.
struct TaskCheckRun: Decodable, Hashable { let status: String?; let conclusion: String?; let state: String? }

struct TaskIssue: Identifiable, Decodable {
    let number: Int
    let title: String
    var state: String
    let url: String
    let labels: [TaskLabel]
    var assignees: [TaskActor]
    let author: TaskActor
    let updatedAt: String
    var id: Int { number }
}

struct TaskPR: Identifiable, Decodable {
    let number: Int
    let title: String
    let headRefName: String
    let baseRefName: String
    let author: TaskActor
    let state: String  // OPEN / CLOSED / MERGED
    let isDraft: Bool
    let updatedAt: String
    let labels: [TaskLabel]
    var reviewRequests: [TaskReviewRequest]
    let statusCheckRollup: [TaskCheckRun]
    var id: Int { number }
}

struct IssueRow: Identifiable {
    let repo: RepoEntry
    var issue: TaskIssue
    var id: String { "\(repo.id)#\(issue.number)" }
}

struct PRRow: Identifiable {
    let repo: RepoEntry
    var pr: TaskPR
    var id: String { "\(repo.id)#\(pr.number)" }
}

extension PRRow {
    var checksSummary: (label: String, color: Color, icon: String) {
        let runs = pr.statusCheckRollup
        if runs.isEmpty { return ("No checks", .mgMuted, "minus") }
        let failing: Set<String?> = ["FAILURE", "ERROR"]
        if runs.contains(where: { failing.contains($0.conclusion) || failing.contains($0.state) }) { return ("Failing", .red, "xmark.circle.fill") }
        if runs.contains(where: { ($0.status ?? "COMPLETED") != "COMPLETED" }) { return ("Pending", .yellow, "clock.fill") }
        return ("Passing", Color(red: 0.35, green: 0.85, blue: 0.55), "checkmark.circle.fill")
    }
}

// A cross-repo generalization of RepoDetailView's branch list (ManagementView.swift) — same
// remote/local detection, aggregated across every connected repo instead of one at a time.
struct BranchRow: Identifiable, Sendable {
    let repo: RepoEntry
    let name: String
    let isRemote: Bool
    let isLocal: Bool
    var id: String { "\(repo.id)#\(name)" }
}

// Plain `git` shellouts (no `gh`/GitHub API needed) — mirrors RepoDetailView.fetchBranches().
nonisolated private func fetchBranchesForRepo(repo: RepoEntry, mainClonePath: String?) -> [BranchRow] {
    var remoteNames: Set<String> = []
    if !repo.url.isEmpty {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["ls-remote", "--heads", repo.url]
        p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        remoteNames = Set(out.split(separator: "\n").compactMap { line -> String? in
            guard let ref = line.split(separator: "\t").last else { return nil }
            return String(ref).replacingOccurrences(of: "refs/heads/", with: "")
        })
    }
    var localNames: Set<String> = []
    if let root = mainClonePath, FileManager.default.fileExists(atPath: root) {
        let p2 = Process(); let pipe2 = Pipe()
        p2.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p2.arguments = ["-C", root, "branch", "--format=%(refname:short)"]
        p2.standardOutput = pipe2; p2.standardError = Pipe()
        try? p2.run(); p2.waitUntilExit()
        let out2 = String(data: pipe2.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        localNames = Set(out2.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
    let allNames = remoteNames.union(localNames).union([repo.defaultBranch])
    return allNames.map { BranchRow(repo: repo, name: $0, isRemote: remoteNames.contains($0), isLocal: localNames.contains($0)) }
}

func fetchBranchesAcrossRepos(_ repos: [RepoEntry], settings: AppSettings) async -> [BranchRow] {
    var mainPaths: [String: String?] = [:]
    for repo in repos { mainPaths[repo.id] = await mainClonePath(for: repo, settings: settings) }
    var rows: [BranchRow] = []
    await withTaskGroup(of: [BranchRow].self) { group in
        for repo in repos where gitURLComponents(repo.url) != nil {
            let path = mainPaths[repo.id] ?? nil
            group.addTask { fetchBranchesForRepo(repo: repo, mainClonePath: path) }
        }
        for await result in group { rows.append(contentsOf: result) }
    }
    rows.sort { (a: BranchRow, b: BranchRow) -> Bool in
        if a.repo.name != b.repo.name { return a.repo.name < b.repo.name }
        if a.isLocal != b.isLocal { return a.isLocal }
        return a.name < b.name
    }
    return rows
}

func taskRelativeTime(_ iso: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

// MARK: - gh CLI plumbing

struct TaskGHError: Error { let message: String }

nonisolated private func runGH(_ arguments: [String]) -> Result<Data, TaskGHError> {
    guard let ghPath = resolveGHPath() else {
        return .failure(TaskGHError(message: "gh CLI not found — install from https://cli.github.com"))
    }
    let p = Process(); let outPipe = Pipe(); let errPipe = Pipe()
    p.executableURL = URL(fileURLWithPath: ghPath)
    p.arguments = arguments
    p.standardOutput = outPipe; p.standardError = errPipe
    do { try p.run() } catch { return .failure(TaskGHError(message: error.localizedDescription)) }
    p.waitUntilExit()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    if p.terminationStatus != 0 {
        let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .failure(TaskGHError(message: msg.isEmpty ? "gh command failed" : msg))
    }
    return .success(outData)
}

// "is:issue"/"is:pr" are decorative in the search box (kept for visual parity with GitHub's own
// combined search) but redundant here since each gh subcommand is already scoped to one type.
nonisolated private func cleanedSearchQuery(_ query: String) -> String {
    let kept = query.split(separator: " ").filter { $0 != "is:issue" && $0 != "is:pr" && $0 != "is:open" && $0 != "is:closed" }
    return kept.joined(separator: " ")
}

// gh defaults --state to "open" whenever it's left unset, silently ANDing that onto --search —
// so a bare number search or the "All"/"Closed" filter (no is:open/is:closed token) would still
// only ever return open items unless --state is passed explicitly here.
nonisolated private func ghStateArg(_ query: String) -> String {
    let tokens = query.split(separator: " ").map(String.init)
    if tokens.contains("is:closed") { return "closed" }
    if tokens.contains("is:open") { return "open" }
    return "all"
}

// MARK: - GitHub repo discovery (for the Projects filter — broader than db.repos)

struct TaskGHRepoListing: Identifiable, Decodable, Hashable {
    struct DefaultBranchRef: Decodable, Hashable { let name: String }
    let nameWithOwner: String
    let url: String
    let defaultBranchRef: DefaultBranchRef?
    var id: String { url }
}

nonisolated func fetchTaskGHRepoListings(owner: String = "") -> [TaskGHRepoListing] {
    var args = ["repo", "list"]
    if !owner.isEmpty { args.append(owner) }
    args += ["--json", "nameWithOwner,url,defaultBranchRef", "--limit", "200"]
    switch runGH(args) {
    case .failure: return []
    case .success(let data): return (try? JSONDecoder().decode([TaskGHRepoListing].self, from: data)) ?? []
    }
}

nonisolated func fetchTaskGHOrgs() -> [String] {
    switch runGH(["api", "user/orgs", "--jq", ".[].login"]) {
    case .failure: return []
    case .success(let data):
        let out = String(data: data, encoding: .utf8) ?? ""
        return out.split(separator: "\n").map(String.init)
    }
}

nonisolated private func fetchIssues(repo: RepoEntry, query: String) -> Result<[TaskIssue], TaskGHError> {
    guard let (org, name) = gitURLComponents(repo.url) else { return .success([]) }
    var args = ["issue", "list", "--repo", "\(org)/\(name)", "--state", ghStateArg(query)]
    let search = cleanedSearchQuery(query)
    if !search.isEmpty { args += ["--search", search] }
    args += ["--json", "number,title,state,url,labels,assignees,author,updatedAt", "--limit", "50"]
    switch runGH(args) {
    case .failure(let err): return .failure(err)
    case .success(let data): return .success((try? JSONDecoder().decode([TaskIssue].self, from: data)) ?? [])
    }
}

nonisolated private func fetchPRs(repo: RepoEntry, query: String) -> Result<[TaskPR], TaskGHError> {
    guard let (org, name) = gitURLComponents(repo.url) else { return .success([]) }
    var args = ["pr", "list", "--repo", "\(org)/\(name)", "--state", ghStateArg(query)]
    let search = cleanedSearchQuery(query)
    if !search.isEmpty { args += ["--search", search] }
    args += ["--json", "number,title,headRefName,baseRefName,author,state,isDraft,updatedAt,labels,reviewRequests,statusCheckRollup", "--limit", "50"]
    switch runGH(args) {
    case .failure(let err): return .failure(err)
    case .success(let data): return .success((try? JSONDecoder().decode([TaskPR].self, from: data)) ?? [])
    }
}

func fetchIssuesAcrossRepos(_ repos: [RepoEntry], query: String) async -> ([IssueRow], String?) {
    var rows: [IssueRow] = []
    var lastError: String? = nil
    await withTaskGroup(of: (RepoEntry, Result<[TaskIssue], TaskGHError>).self) { group in
        for repo in repos where gitURLComponents(repo.url) != nil {
            group.addTask { (repo, fetchIssues(repo: repo, query: query)) }
        }
        for await (repo, result) in group {
            switch result {
            case .success(let issues): rows.append(contentsOf: issues.map { IssueRow(repo: repo, issue: $0) })
            case .failure(let err): lastError = err.message
            }
        }
    }
    rows.sort { $0.issue.updatedAt > $1.issue.updatedAt }
    return (rows, rows.isEmpty ? lastError : nil)
}

func fetchPRsAcrossRepos(_ repos: [RepoEntry], query: String) async -> ([PRRow], String?) {
    var rows: [PRRow] = []
    var lastError: String? = nil
    await withTaskGroup(of: (RepoEntry, Result<[TaskPR], TaskGHError>).self) { group in
        for repo in repos where gitURLComponents(repo.url) != nil {
            group.addTask { (repo, fetchPRs(repo: repo, query: query)) }
        }
        for await (repo, result) in group {
            switch result {
            case .success(let prs): rows.append(contentsOf: prs.map { PRRow(repo: repo, pr: $0) })
            case .failure(let err): lastError = err.message
            }
        }
    }
    rows.sort { $0.pr.updatedAt > $1.pr.updatedAt }
    return (rows, rows.isEmpty ? lastError : nil)
}

// MARK: - Issue mutations (actionable status/assignee dropdowns)

// `reason` mirrors GitHub's own close options ("completed" / "not planned") — passed straight
// through to `gh issue close --reason`; nil (reopen, or a plain close) omits the flag.
func setIssueState(_ row: IssueRow, closed: Bool, reason: String? = nil) async -> Result<Void, TaskGHError> {
    guard let (org, name) = gitURLComponents(row.repo.url) else {
        return .failure(TaskGHError(message: "Not a GitHub repo"))
    }
    var args = ["issue", closed ? "close" : "reopen", String(row.issue.number), "--repo", "\(org)/\(name)"]
    if closed, let reason { args += ["--reason", reason] }
    return await Task.detached {
        runGH(args).map { _ in () }
    }.value
}

// Users assignable to issues in this repo (GitHub's own "assignees" endpoint — the same list
// GitHub.com's own assignee dropdown offers), for the row-level assignee picker.
nonisolated private func fetchAssignableUsersSync(repo: RepoEntry) -> [TaskActor] {
    guard let (org, name) = gitURLComponents(repo.url) else { return [] }
    switch runGH(["api", "repos/\(org)/\(name)/assignees", "--paginate"]) {
    case .failure: return []
    case .success(let data): return (try? JSONDecoder().decode([TaskActor].self, from: data)) ?? []
    }
}

func fetchAssignableUsers(repo: RepoEntry) async -> [TaskActor] {
    await Task.detached { fetchAssignableUsersSync(repo: repo) }.value
}

func setIssueAssignee(_ row: IssueRow, login: String, add: Bool) async -> Result<Void, TaskGHError> {
    guard let (org, name) = gitURLComponents(row.repo.url) else {
        return .failure(TaskGHError(message: "Not a GitHub repo"))
    }
    let flag = add ? "--add-assignee" : "--remove-assignee"
    return await Task.detached {
        runGH(["issue", "edit", String(row.issue.number), "--repo", "\(org)/\(name)", flag, login])
            .map { _ in () }
    }.value
}

// `--body` is always passed (even empty) — omitting it makes `gh` fall back to an interactive
// prompt, which hangs forever since this process has no TTY.
func createIssue(repo: RepoEntry, title: String, body: String) async -> Result<Void, TaskGHError> {
    guard let (org, name) = gitURLComponents(repo.url) else {
        return .failure(TaskGHError(message: "Not a GitHub repo"))
    }
    let args = ["issue", "create", "--repo", "\(org)/\(name)", "--title", title, "--body", body]
    return await Task.detached {
        runGH(args).map { _ in () }
    }.value
}

// MARK: - PR mutations (actionable reviewer dropdown)

func createPR(repo: RepoEntry, title: String, head: String, base: String, body: String) async -> Result<Void, TaskGHError> {
    guard let (org, name) = gitURLComponents(repo.url) else {
        return .failure(TaskGHError(message: "Not a GitHub repo"))
    }
    let args = ["pr", "create", "--repo", "\(org)/\(name)", "--title", title, "--head", head, "--base", base, "--body", body]
    return await Task.detached {
        runGH(args).map { _ in () }
    }.value
}

func setPRReviewer(_ row: PRRow, login: String, add: Bool) async -> Result<Void, TaskGHError> {
    guard let (org, name) = gitURLComponents(row.repo.url) else {
        return .failure(TaskGHError(message: "Not a GitHub repo"))
    }
    let flag = add ? "--add-reviewer" : "--remove-reviewer"
    return await Task.detached {
        runGH(["pr", "edit", String(row.pr.number), "--repo", "\(org)/\(name)", flag, login])
            .map { _ in () }
    }.value
}

// MARK: - "Start"/"Open" — launch a scoped workspace for an issue/PR

@MainActor
func worktreePath(for repo: RepoEntry, branch: String, settings: AppSettings) -> String? {
    guard let base = settings.baseWorkingDirectory else { return nil }
    return repoBranchPath(base: base, repoURL: repo.url, repoName: repo.name, branch: branch)
}

@MainActor
func mainClonePath(for repo: RepoEntry, settings: AppSettings) -> String? {
    worktreePath(for: repo, branch: repo.defaultBranch, settings: settings)
}

@MainActor
func isMainCloned(for repo: RepoEntry, settings: AppSettings) -> Bool {
    guard let p = mainClonePath(for: repo, settings: settings) else { return false }
    return FileManager.default.fileExists(atPath: p)
}

@MainActor
private func openTaskWorkspace(path: String, name: String, folderName: String, branchRef: String) {
    NotificationCenter.default.post(
        name: .srotaOpenWorkspace, object: nil,
        userInfo: ["path": path, "name": name, "folderName": folderName, "folderTag": "",
                   "createWorktree": false, "projectPath": path, "branchRef": branchRef]
    )
}

@MainActor
func startIssueWorkspace(_ row: IssueRow, settings: AppSettings) async -> Result<Void, TaskGHError> {
    let branchName = "issue/\(row.issue.number)"
    guard let path = worktreePath(for: row.repo, branch: branchName, settings: settings),
          let mainPath = mainClonePath(for: row.repo, settings: settings), isMainCloned(for: row.repo, settings: settings)
    else { return .failure(TaskGHError(message: "Clone \(row.repo.defaultBranch) first in Repos")) }

    if FileManager.default.fileExists(atPath: path) {
        openTaskWorkspace(path: path, name: branchName, folderName: row.repo.name, branchRef: branchName)
        return .success(())
    }

    let base = row.repo.defaultBranch
    let result = await Task.detached { () -> Result<Void, TaskGHError> in
        let p = Process(); let errPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", mainPath, "worktree", "add", path, "-b", branchName, base]
        p.standardError = errPipe
        do { try p.run() } catch { return .failure(TaskGHError(message: error.localizedDescription)) }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(TaskGHError(message: msg.isEmpty ? "git worktree add failed" : msg))
        }
        return .success(())
    }.value
    if case .success = result {
        openTaskWorkspace(path: path, name: branchName, folderName: row.repo.name, branchRef: branchName)
    }
    return result
}

// Creates the PR's worktree if it doesn't already exist and returns its path — split out from
// startPRWorkspace so the review-agent launch (which needs the path but not the plain-open
// notification) can reuse the exact same fetch/branch/worktree logic instead of duplicating it.
@MainActor
func ensurePRWorktree(_ row: PRRow, settings: AppSettings) async -> Result<String, TaskGHError> {
    let headRef = row.pr.headRefName
    guard let path = worktreePath(for: row.repo, branch: headRef, settings: settings),
          let mainPath = mainClonePath(for: row.repo, settings: settings), isMainCloned(for: row.repo, settings: settings)
    else { return .failure(TaskGHError(message: "Clone \(row.repo.defaultBranch) first in Repos")) }

    if FileManager.default.fileExists(atPath: path) { return .success(path) }

    let prNumber = row.pr.number
    return await Task.detached { () -> Result<String, TaskGHError> in
        let fetchP = Process(); let fetchErrPipe = Pipe()
        fetchP.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        fetchP.arguments = ["-C", mainPath, "fetch", "origin", "pull/\(prNumber)/head"]
        fetchP.standardError = fetchErrPipe
        do { try fetchP.run() } catch { return .failure(TaskGHError(message: error.localizedDescription)) }
        fetchP.waitUntilExit()
        guard fetchP.terminationStatus == 0 else {
            let msg = String(data: fetchErrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "git fetch failed"
            return .failure(TaskGHError(message: msg))
        }

        // A same-named local branch can be left dangling (its worktree removed elsewhere without
        // deleting the branch ref) — force it to what was just fetched rather than failing outright.
        let branchExistsP = Process()
        branchExistsP.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        branchExistsP.arguments = ["-C", mainPath, "show-ref", "--verify", "--quiet", "refs/heads/\(headRef)"]
        try? branchExistsP.run()
        branchExistsP.waitUntilExit()
        let branchExists = branchExistsP.terminationStatus == 0

        if branchExists {
            let moveP = Process(); let moveErrPipe = Pipe()
            moveP.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            moveP.arguments = ["-C", mainPath, "branch", "-f", headRef, "FETCH_HEAD"]
            moveP.standardError = moveErrPipe
            do { try moveP.run() } catch { return .failure(TaskGHError(message: error.localizedDescription)) }
            moveP.waitUntilExit()
            guard moveP.terminationStatus == 0 else {
                let msg = String(data: moveErrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return .failure(TaskGHError(message: msg.isEmpty ? "git branch update failed" : msg))
            }
        }

        let worktreeP = Process(); let errPipe = Pipe()
        worktreeP.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        worktreeP.arguments = branchExists
            ? ["-C", mainPath, "worktree", "add", path, headRef]
            : ["-C", mainPath, "worktree", "add", path, "-b", headRef, "FETCH_HEAD"]
        worktreeP.standardError = errPipe
        do { try worktreeP.run() } catch { return .failure(TaskGHError(message: error.localizedDescription)) }
        worktreeP.waitUntilExit()
        guard worktreeP.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(TaskGHError(message: msg.isEmpty ? "git worktree add failed" : msg))
        }
        return .success(path)
    }.value
}

@MainActor
func startPRWorkspace(_ row: PRRow, settings: AppSettings) async -> Result<Void, TaskGHError> {
    switch await ensurePRWorktree(row, settings: settings) {
    case .failure(let err): return .failure(err)
    case .success(let path):
        openTaskWorkspace(path: path, name: row.pr.headRefName, folderName: row.repo.name, branchRef: row.pr.headRefName)
        return .success(())
    }
}

// MARK: - Repos/Branches tab mutations (clone, worktree, remove worktree)

@MainActor
func cloneMainBranch(_ repo: RepoEntry, settings: AppSettings) async -> Result<Void, TaskGHError> {
    guard let path = mainClonePath(for: repo, settings: settings) else {
        return .failure(TaskGHError(message: "Set a base working directory in Settings first"))
    }
    if FileManager.default.fileExists(atPath: path) { return .success(()) }
    let url = repo.url; let branch = repo.defaultBranch
    return await Task.detached { () -> Result<Void, TaskGHError> in
        let p = Process(); let errPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["clone", "--branch", branch, url, path]
        p.standardError = errPipe
        do { try p.run() } catch { return .failure(TaskGHError(message: error.localizedDescription)) }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(TaskGHError(message: msg.isEmpty ? "git clone failed" : msg))
        }
        return .success(())
    }.value
}

@MainActor
func startRepoWorkspace(_ repo: RepoEntry, settings: AppSettings) async -> Result<Void, TaskGHError> {
    guard let path = mainClonePath(for: repo, settings: settings) else {
        return .failure(TaskGHError(message: "Set a base working directory in Settings first"))
    }
    if FileManager.default.fileExists(atPath: path) {
        openTaskWorkspace(path: path, name: repo.defaultBranch, folderName: repo.name, branchRef: repo.defaultBranch)
        return .success(())
    }
    let result = await cloneMainBranch(repo, settings: settings)
    if case .success = result {
        openTaskWorkspace(path: path, name: repo.defaultBranch, folderName: repo.name, branchRef: repo.defaultBranch)
    }
    return result
}

@MainActor
func startBranchWorkspace(_ row: BranchRow, settings: AppSettings, baseBranch: String? = nil) async -> Result<Void, TaskGHError> {
    let repo = row.repo; let branch = row.name
    guard let path = worktreePath(for: repo, branch: branch, settings: settings) else {
        return .failure(TaskGHError(message: "Set a base working directory in Settings first"))
    }
    if branch == repo.defaultBranch {
        let result = await cloneMainBranch(repo, settings: settings)
        if case .success = result {
            openTaskWorkspace(path: path, name: branch, folderName: repo.name, branchRef: branch)
        }
        return result
    }
    if FileManager.default.fileExists(atPath: path) {
        openTaskWorkspace(path: path, name: branch, folderName: repo.name, branchRef: branch)
        return .success(())
    }
    guard let mainPath = mainClonePath(for: repo, settings: settings), isMainCloned(for: repo, settings: settings) else {
        return .failure(TaskGHError(message: "Clone \(repo.defaultBranch) first"))
    }
    // A branch that's neither remote nor local doesn't exist as a ref yet (e.g. just typed into
    // the Branches tab's "+" sheet) — create it off the chosen base branch (defaulting to the
    // repo's default branch) instead of checking it out.
    let isNewBranch = !row.isRemote && !row.isLocal
    let base = baseBranch ?? repo.defaultBranch
    let result = await Task.detached { () -> Result<Void, TaskGHError> in
        let p = Process(); let errPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = isNewBranch
            ? ["-C", mainPath, "worktree", "add", "-b", branch, path, base]
            : ["-C", mainPath, "worktree", "add", path, branch]
        p.standardError = errPipe
        do { try p.run() } catch { return .failure(TaskGHError(message: error.localizedDescription)) }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(TaskGHError(message: msg.isEmpty ? "git worktree add failed" : msg))
        }
        return .success(())
    }.value
    if case .success = result {
        openTaskWorkspace(path: path, name: branch, folderName: repo.name, branchRef: branch)
    }
    return result
}

@MainActor
func removeBranchWorkspace(_ row: BranchRow, settings: AppSettings) async -> Result<Void, TaskGHError> {
    guard let path = worktreePath(for: row.repo, branch: row.name, settings: settings),
          let mainPath = mainClonePath(for: row.repo, settings: settings)
    else { return .failure(TaskGHError(message: "Not found")) }
    return await Task.detached { () -> Result<Void, TaskGHError> in
        let p = Process(); let errPipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", mainPath, "worktree", "remove", "--force", path]
        p.standardError = errPipe
        do { try p.run() } catch { return .failure(TaskGHError(message: error.localizedDescription)) }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(TaskGHError(message: msg.isEmpty ? "git worktree remove failed" : msg))
        }
        return .success(())
    }.value
}

// MARK: - Search-query token helpers (Filters dropdown reads/writes these directly)

func queryValue(_ prefix: String, in query: String) -> String? {
    query.split(separator: " ").first(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
}

func queryRemoving(_ prefix: String, from query: String) -> String {
    query.split(separator: " ").filter { !$0.hasPrefix(prefix) }.joined(separator: " ")
}

func querySetting(_ prefix: String, value: String, in query: String) -> String {
    let stripped = queryRemoving(prefix, from: query)
    return stripped.isEmpty ? prefix + value : stripped + " " + prefix + value
}
