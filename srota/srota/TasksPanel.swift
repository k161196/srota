import SwiftUI
import AppKit

// Aggregated, gh-backed view of Issues/PRs across every repo registered in Srota (WorkspaceDB.repos),
// surfaced as a top-level tab so you don't have to drill into a single repo to see what's open.
// See RepoDetailView (ManagementView.swift) for the single-repo precedent this generalizes from.

// Mirrors ManagementView.swift's private Color.mg* palette — duplicated here since that
// extension is file-private and this view lives in a different file (same convention GitHubProjectsPanel.swift uses).
private extension Color {
    static let mgBg        = Color(red: 0.067, green: 0.067, blue: 0.075)
    static let mgSurface   = Color(red: 0.10,  green: 0.10,  blue: 0.11)
    static let mgBorder    = Color.white.opacity(0.07)
    static let mgAccent    = Color(red: 1.0, green: 0.45, blue: 0.15)
    static let mgLabel     = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let mgMuted     = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.40)
    static let mgRow       = Color.white.opacity(0.035)
    static let mgRowHover  = Color.white.opacity(0.065)
}

// MARK: - GitHub models

struct TaskActor: Decodable, Hashable { let login: String }
struct TaskLabel: Decodable, Hashable { let name: String }
struct TaskReviewRequest: Decodable, Hashable {
    let login: String?
    let name: String?
    var displayName: String { login ?? name ?? "team" }
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
    let author: TaskActor
    let state: String  // OPEN / CLOSED / MERGED
    let isDraft: Bool
    let updatedAt: String
    let labels: [TaskLabel]
    let reviewRequests: [TaskReviewRequest]
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
    var checksSummary: (label: String, color: Color) {
        let runs = pr.statusCheckRollup
        if runs.isEmpty { return ("No checks", .mgMuted) }
        let failing: Set<String?> = ["FAILURE", "ERROR"]
        if runs.contains(where: { failing.contains($0.conclusion) || failing.contains($0.state) }) { return ("Failing", .red) }
        if runs.contains(where: { ($0.status ?? "COMPLETED") != "COMPLETED" }) { return ("Pending", .yellow) }
        return ("Passing", Color(red: 0.35, green: 0.85, blue: 0.55))
    }
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
    let kept = query.split(separator: " ").filter { $0 != "is:issue" && $0 != "is:pr" }
    let joined = kept.joined(separator: " ")
    return joined.isEmpty ? "is:open" : joined
}

nonisolated private func fetchIssues(repo: RepoEntry, query: String) -> Result<[TaskIssue], TaskGHError> {
    guard let (org, name) = gitURLComponents(repo.url) else { return .success([]) }
    let args = ["issue", "list", "--repo", "\(org)/\(name)",
                "--search", cleanedSearchQuery(query),
                "--json", "number,title,state,url,labels,assignees,author,updatedAt",
                "--limit", "50"]
    switch runGH(args) {
    case .failure(let err): return .failure(err)
    case .success(let data): return .success((try? JSONDecoder().decode([TaskIssue].self, from: data)) ?? [])
    }
}

nonisolated private func fetchPRs(repo: RepoEntry, query: String) -> Result<[TaskPR], TaskGHError> {
    guard let (org, name) = gitURLComponents(repo.url) else { return .success([]) }
    let args = ["pr", "list", "--repo", "\(org)/\(name)",
                "--search", cleanedSearchQuery(query),
                "--json", "number,title,headRefName,author,state,isDraft,updatedAt,labels,reviewRequests,statusCheckRollup",
                "--limit", "50"]
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

func setIssueState(_ row: IssueRow, closed: Bool) async -> Result<Void, TaskGHError> {
    guard let (org, name) = gitURLComponents(row.repo.url) else {
        return .failure(TaskGHError(message: "Not a GitHub repo"))
    }
    return await Task.detached {
        runGH(["issue", closed ? "close" : "reopen", String(row.issue.number), "--repo", "\(org)/\(name)"])
            .map { _ in () }
    }.value
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

@MainActor
func startPRWorkspace(_ row: PRRow, settings: AppSettings) async -> Result<Void, TaskGHError> {
    let headRef = row.pr.headRefName
    guard let path = worktreePath(for: row.repo, branch: headRef, settings: settings),
          let mainPath = mainClonePath(for: row.repo, settings: settings), isMainCloned(for: row.repo, settings: settings)
    else { return .failure(TaskGHError(message: "Clone \(row.repo.defaultBranch) first in Repos")) }

    if FileManager.default.fileExists(atPath: path) {
        openTaskWorkspace(path: path, name: headRef, folderName: row.repo.name, branchRef: headRef)
        return .success(())
    }

    let prNumber = row.pr.number
    let result = await Task.detached { () -> Result<Void, TaskGHError> in
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
        return .success(())
    }.value
    if case .success = result {
        openTaskWorkspace(path: path, name: headRef, folderName: row.repo.name, branchRef: headRef)
    }
    return result
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
