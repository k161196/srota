import Foundation

// Locates the gh CLI binary; GUI apps don't inherit the login shell's PATH.
func resolveGHPath() -> String? {
    for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] {
        if FileManager.default.fileExists(atPath: path) { return path }
    }
    let p = Process(); let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "which gh"]
    p.standardOutput = pipe; p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return out.isEmpty ? nil : out
}

// Parses git@github.com:org/repo.git or https://github.com/org/repo[.git]
func gitURLComponents(_ url: String) -> (org: String, repo: String)? {
    var s = url
    for prefix in ["git@github.com:", "https://github.com/", "http://github.com/"] {
        if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)); break }
    }
    s = s.replacingOccurrences(of: ".git", with: "")
    let parts = s.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
    return (parts[0], parts[1])
}

// Canonical on-disk checkout location for a (repo, branch) pair — shared by RepoDetailView.branchPath
// and the multi-repo workspace flow, so both agree on where an existing checkout lives.
func repoBranchPath(base: String, repoURL: String, repoName: String, branch: String) -> String {
    let safeName = branch.replacingOccurrences(of: "/", with: "-")
    if let (org, repo) = gitURLComponents(repoURL) {
        let safeOrg = org.replacingOccurrences(of: "/", with: "-")
        let safeRepo = repo.replacingOccurrences(of: "/", with: "-")
        return "\(base)/organizations/\(safeOrg)/projects/\(safeRepo)/branches/\(safeName)"
    }
    let safeRepo = repoName.replacingOccurrences(of: "/", with: "-")
    return "\(base)/repos/\(safeRepo)/branches/\(safeName)"
}

// Extracts the issue number from branch names like "issue/508-fix-login-crash" or "issue-508-fix-login-crash".
func extractIssueNumber(fromBranch branch: String) -> Int? {
    guard let regex = try? NSRegularExpression(pattern: #"issue[/-](\d+)"#),
          let match = regex.firstMatch(in: branch, range: NSRange(branch.startIndex..., in: branch)),
          let range = Range(match.range(at: 1), in: branch)
    else { return nil }
    return Int(branch[range])
}

func runGit(_ arguments: [String]) -> String? {
    let p = Process(); let outPipe = Pipe(); let errPipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = arguments
    p.standardOutput = outPipe; p.standardError = errPipe
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (out?.isEmpty ?? true) ? nil : out
}
