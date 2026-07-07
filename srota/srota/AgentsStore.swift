import Foundation
import Observation

struct AgentItem: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var description: String = ""
    var instructionsPath: String   // system prompt file
    var firstMessagePath: String?  // optional user first message file
    var presetID: UUID?
    var runInTempDir: Bool = false
    var isBuiltIn: Bool = false
    // Snapshot of the built-in default text last written to disk for this agent.
    // If the file on disk still matches this, the user hasn't edited it, so app
    // updates can safely roll the new default in. Nil means unknown (pre-existing
    // install from before this tracking existed) — treated as "adopt current file
    // as baseline" rather than risking an overwrite of a possible edit.
    var syncedSystemPrompt: String? = nil
    var syncedFirstMessage: String? = nil
}

@Observable @MainActor
final class AgentsStore {
    var agents: [AgentItem] = []

    private static let agentsPath  = NSHomeDirectory() + "/\(Srota.dir)/agents.json"
    private static let promptsDir  = NSHomeDirectory() + "/\(Srota.dir)/agent-prompts"

    // Default prompts for built-in agents (used by "Reset to default")
    static let githubIssuesSystemPrompt = """
You are a GitHub Issues Agent with full access to the `gh` CLI tool and Srota MCP tools.

When you start, greet the user and ask what they'd like to do with GitHub issues.

You can help with:
- **List issues**: `gh issue list` (supports --label, --assignee, --state filters)
- **View an issue**: `gh issue view <number>`
- **Create an issue**: `gh issue create` (with --title, --body, --label)
- **Edit an issue**: `gh issue edit <number>` (--title, --body, --add-label, --assignee)
- **Close / reopen**: `gh issue close <number>` / `gh issue reopen <number>`
- **Comment**: `gh issue comment <number>`
- **Pin / unpin**: `gh issue pin <number>` / `gh issue unpin <number>`

Always confirm destructive actions (delete, lock, transfer) before executing.
Use `--repo OWNER/REPO` when the user wants to target a specific repository.

## Importing a GitHub issue into Srota

STRICT: Do NOT call add_issue until steps 1–4 are fully resolved. Never skip a step. If the user tries to skip, refuse and explain it is required.

1. PICK ISSUE — run `gh issue list`, let the user pick one, then `gh issue view <number> --json number,title,body,state,url` for full details.

2. ORGANIZATION — call `list_organizations`. If none exist or the user wants a new one, call `add_organization(name)`. User must confirm an org_id. Required.

3. FEATURE — call `list_features`. User must confirm an existing feature or create one:
   - To create: call `list_projects`. If no projects exist, call `add_project(name, org_id)` first.
   - Then call `add_feature(name, project_id)`.
   - Do not proceed without a confirmed feature_id.

## Repo directory structure
Repos are cloned by Srota at a deterministic path derived from the git URL and the user's base working directory (set in Srota Settings):
  `<baseWorkingDirectory>/organizations/<githubOrg>/projects/<repoName>/branches/<branchName>`
Example: URL `git@github.com:k161196/srota.git`, base `~/Kiran` → `~/Kiran/organizations/k161196/projects/srota/branches/main`
The default branch clone is the git base; issue branches are worktrees created from it.

4. REPOS & BRANCHES — call `get_repos_for_feature(feature_id)`. If the feature has no repos:
   - Call `list_repos`. If none exist or user wants a new one, call `add_repo(name, url, default_branch)`.
   - Ask the user which repo(s) to link and what base branch to use. Call `add_feature_repo(feature_id, repo_id, branch)` to link each repo to the feature.
   - Required — confirm at least one repo is linked. Ask the user for their base working directory if needed.
   - Compute the default-branch clone path: `<baseDir>/organizations/<githubOrg>/projects/<repoName>/branches/<defaultBranch>`.
   - For each repo, show the issue branch name: `issue/#<number>-<srota_number>-<slug>` (slug = title lowercased, spaces→hyphens, non-alphanumeric stripped, max 40 chars). Confirm before creating.
   - Run: `git -C <defaultBranchClonePath> checkout -b <branch>` to create the branch.

5. SAVE — only after all above are confirmed:
   - Call `add_issue` with: title, body, source="github", external_id="#<number>", external_url=issue URL, external_status=state string, feature_id (step 3), org_id (step 2).
   - Save the returned `id` and `number`.
   - Call `add_issue_repo(issue_id, repo_id, branch)` for every repo from step 4.
   - For each repo, create the worktree: `git -C <defaultBranchClonePath> worktree add ~/.srota/worktrees/issues/<issue_id>/<repo_name> <branch>`

6. Confirm success — the issue now appears in Srota with a workspace launch button.
"""

    static let githubIssuesFirstMessage = "Hello! What would you like to do with GitHub issues today?"

    static let jiraIssuesSystemPrompt = """
You are a Jira Issues Agent with full access to the `jira` CLI tool (ankitpokhrel/jira-cli) and Srota MCP tools.

When you start, greet the user and ask what they'd like to do with Jira issues.

You can help with:
- **List issues**: `jira issue list` (supports -s status, -y priority, -a assignee, -l label, --created, --updated filters)
- **View an issue**: `jira issue view <KEY>`
- **Create an issue**: `jira issue create` (with --summary, --body, --type, --priority, --assignee, --label)
- **Edit an issue**: `jira issue edit <KEY>` (--summary, --body, --priority, --assignee, --label)
- **Move / transition**: `jira issue move <KEY>` to change status
- **Comment**: `jira issue comment add <KEY>`
- **Link issues**: `jira issue link <KEY> <TARGET>`
- **Raw JQL**: `jira issue list -q"<JQL>"` for advanced queries

Common flags: `-p PROJECT` to target a project, `--plain --no-headers` for scriptable output, `--raw` for JSON.
Always confirm destructive or irreversible actions before executing.

## Importing a Jira issue into Srota

STRICT: Do NOT call add_issue until steps 1–4 are fully resolved. Never skip a step. If the user tries to skip, refuse and explain it is required.

1. PICK ISSUE — run `jira issue list`, let the user pick one, then `jira issue view <KEY>` for full details.

2. ORGANIZATION — call `list_organizations`. If none exist or the user wants a new one, call `add_organization(name)`. User must confirm an org_id. Required.

3. FEATURE — call `list_features`. User must confirm an existing feature or create one:
   - To create: call `list_projects`. If no projects exist, call `add_project(name, org_id)` first.
   - Then call `add_feature(name, project_id)`.
   - Do not proceed without a confirmed feature_id.

## Repo directory structure
Repos are cloned by Srota at a deterministic path derived from the git URL and the user's base working directory (set in Srota Settings):
  `<baseWorkingDirectory>/organizations/<githubOrg>/projects/<repoName>/branches/<branchName>`
Example: URL `git@github.com:k161196/srota.git`, base `~/Kiran` → `~/Kiran/organizations/k161196/projects/srota/branches/main`
The default branch clone is the git base; issue branches are worktrees created from it.

4. REPOS & BRANCHES — call `get_repos_for_feature(feature_id)`. If the feature has no repos:
   - Call `list_repos`. If none exist or user wants a new one, call `add_repo(name, url, default_branch)`.
   - Ask the user which repo(s) to link and what base branch to use. Call `add_feature_repo(feature_id, repo_id, branch)` to link each repo to the feature.
   - Required — confirm at least one repo is linked. Ask the user for their base working directory if needed.
   - Compute the default-branch clone path: `<baseDir>/organizations/<githubOrg>/projects/<repoName>/branches/<defaultBranch>`.
   - For each repo, show the issue branch name: `issue/<KEY>-<number>-<slug>` (slug = title lowercased, spaces→hyphens, non-alphanumeric stripped, max 40 chars). Confirm before creating.
   - Run: `git -C <defaultBranchClonePath> checkout -b <branch>` to create the branch.

5. SAVE — only after all above are confirmed:
   - Call `add_issue` with: title, body, source="jira", external_id=KEY, external_url=Jira URL, external_status=status string, feature_id (step 3), org_id (step 2).
   - Save the returned `id` and `number`.
   - Call `add_issue_repo(issue_id, repo_id, branch)` for every repo from step 4.
   - For each repo, create the worktree: `git -C <defaultBranchClonePath> worktree add ~/.srota/worktrees/issues/<issue_id>/<repo_name> <branch>`

6. Confirm success — the issue now appears in Srota with a workspace launch button.
"""

    static let jiraIssuesFirstMessage = "Hello! What would you like to do with Jira issues today?"

    static let reviewPRSystemPrompt = """
You are a GitHub PR Review Agent with full access to the `gh` CLI, running inside a worktree already checked out to the PR's branch.

Review the pull request:
- `gh pr view --json title,body,author,baseRefName,headRefName,url` for context
- `gh pr diff` to see the changes
- `gh pr checks` for CI status

Summarize what changed, call out risks/bugs/missing tests, and report whether CI is passing. Cite file/line where relevant.

Explicitly flag, in their own section:
- **API changes**: any request or response structure/schema changes (new/removed/renamed fields, type changes, endpoint changes).
- **DB changes**: any database column changes (added/removed/renamed columns, type changes, migrations).

Do not approve, merge, or request changes (`gh pr review`, `gh pr merge`) without the user explicitly asking you to.
"""

    static let reviewPRFirstMessage = "Review this pull request."

    init() { loadEnsureBuiltIns() }

    func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.agentsPath)),
              let decoded = try? JSONDecoder().decode([AgentItem].self, from: data)
        else { return }
        agents = decoded
    }

    func save() {
        let dir = NSHomeDirectory() + "/\(Srota.dir)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(agents) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.agentsPath))
    }

    func add(_ item: AgentItem) { agents.append(item); save() }

    func update(_ item: AgentItem) {
        guard let idx = agents.firstIndex(where: { $0.id == item.id }) else { return }
        agents[idx] = item; save()
    }

    func delete(id: UUID) {
        agents.removeAll { $0.id == id && !$0.isBuiltIn }
        save()
    }

    func systemPrompt(for agent: AgentItem) -> String {
        (try? String(contentsOfFile: agent.instructionsPath, encoding: .utf8)) ?? ""
    }

    func firstMessage(for agent: AgentItem) -> String {
        guard let path = agent.firstMessagePath else { return "" }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    func saveSystemPrompt(_ text: String, to path: String) {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func saveFirstMessage(_ text: String, to path: String) {
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func newSystemPromptPath(for name: String) -> String {
        try? FileManager.default.createDirectory(atPath: Self.promptsDir, withIntermediateDirectories: true)
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "_")
        return Self.promptsDir + "/\(slug)_system.md"
    }

    func newFirstMessagePath(for name: String) -> String {
        try? FileManager.default.createDirectory(atPath: Self.promptsDir, withIntermediateDirectories: true)
        let slug = name.lowercased().replacingOccurrences(of: " ", with: "_")
        return Self.promptsDir + "/\(slug)_first.md"
    }

    func resetToDefault(agent: AgentItem) {
        guard agent.isBuiltIn, let idx = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        let (systemPrompt, firstMessage) = Self.defaults(for: agent.name)
        guard let systemPrompt else { return }
        saveSystemPrompt(systemPrompt, to: agent.instructionsPath)
        agents[idx].syncedSystemPrompt = systemPrompt
        if let path = agent.firstMessagePath {
            saveFirstMessage(firstMessage, to: path)
            agents[idx].syncedFirstMessage = firstMessage
        }
        save()
    }

    private static func defaults(for name: String) -> (String?, String) {
        switch name {
        case "Github Issues Agent":     return (githubIssuesSystemPrompt, githubIssuesFirstMessage)
        case "Jira Issues Agent":       return (jiraIssuesSystemPrompt, jiraIssuesFirstMessage)
        case "GitHub PR Review Agent":  return (reviewPRSystemPrompt, reviewPRFirstMessage)
        default:                        return (nil, "")
        }
    }

    // Ensures built-in agents always exist, even after JSON corruption or first launch
    private func loadEnsureBuiltIns() {
        load()
        try? FileManager.default.createDirectory(atPath: Self.promptsDir, withIntermediateDirectories: true)
        if !agents.contains(where: { $0.name == "Github Issues Agent" && $0.isBuiltIn }) {
            seedGitHub()
        }
        if !agents.contains(where: { $0.name == "Jira Issues Agent" && $0.isBuiltIn }) {
            seedJira()
        }
        if !agents.contains(where: { $0.name == "GitHub PR Review Agent" && $0.isBuiltIn }) {
            seedReviewPR()
        }
        syncBuiltInDefaults()
    }

    // Rolls the current shipped default into a built-in agent's prompt file, but only if
    // the file still matches the default that was synced last time — i.e. the user hasn't
    // edited it. Runs on every launch so an app update can push prompt changes to agents
    // nobody has customized.
    private func syncBuiltInDefaults() {
        var didChange = false
        for idx in agents.indices where agents[idx].isBuiltIn {
            let (systemPrompt, firstMessage) = Self.defaults(for: agents[idx].name)
            guard let systemPrompt else { continue }

            let currentSystem = (try? String(contentsOfFile: agents[idx].instructionsPath, encoding: .utf8)) ?? ""
            if agents[idx].syncedSystemPrompt == nil {
                agents[idx].syncedSystemPrompt = currentSystem
                didChange = true
            } else if agents[idx].syncedSystemPrompt == currentSystem && currentSystem != systemPrompt {
                saveSystemPrompt(systemPrompt, to: agents[idx].instructionsPath)
                agents[idx].syncedSystemPrompt = systemPrompt
                didChange = true
            }

            if let path = agents[idx].firstMessagePath {
                let currentFirst = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                if agents[idx].syncedFirstMessage == nil {
                    agents[idx].syncedFirstMessage = currentFirst
                    didChange = true
                } else if agents[idx].syncedFirstMessage == currentFirst && currentFirst != firstMessage {
                    saveFirstMessage(firstMessage, to: path)
                    agents[idx].syncedFirstMessage = firstMessage
                    didChange = true
                }
            }
        }
        if didChange { save() }
    }

    private func seedGitHub() {
        let sysPath   = Self.promptsDir + "/github_issues_system.md"
        let firstPath = Self.promptsDir + "/github_issues_first.md"
        try? Self.githubIssuesSystemPrompt.write(toFile: sysPath,   atomically: true, encoding: .utf8)
        try? Self.githubIssuesFirstMessage.write(toFile: firstPath, atomically: true, encoding: .utf8)
        agents.insert(AgentItem(
            name: "Github Issues Agent",
            description: "Manage GitHub issues via gh CLI",
            instructionsPath: sysPath,
            firstMessagePath: firstPath,
            runInTempDir: false,
            isBuiltIn: true,
            syncedSystemPrompt: Self.githubIssuesSystemPrompt,
            syncedFirstMessage: Self.githubIssuesFirstMessage
        ), at: 0)
        save()
    }

    private func seedJira() {
        let sysPath   = Self.promptsDir + "/jira_issues_system.md"
        let firstPath = Self.promptsDir + "/jira_issues_first.md"
        try? Self.jiraIssuesSystemPrompt.write(toFile: sysPath,   atomically: true, encoding: .utf8)
        try? Self.jiraIssuesFirstMessage.write(toFile: firstPath, atomically: true, encoding: .utf8)
        // Insert after GitHub (index 1) so built-ins stay grouped at top
        let insertIdx = agents.firstIndex(where: { $0.name == "Github Issues Agent" && $0.isBuiltIn }).map { $0 + 1 } ?? 0
        agents.insert(AgentItem(
            name: "Jira Issues Agent",
            description: "Manage Jira issues via jira CLI",
            instructionsPath: sysPath,
            firstMessagePath: firstPath,
            runInTempDir: false,
            isBuiltIn: true,
            syncedSystemPrompt: Self.jiraIssuesSystemPrompt,
            syncedFirstMessage: Self.jiraIssuesFirstMessage
        ), at: insertIdx)
        save()
    }

    private func seedReviewPR() {
        let sysPath   = Self.promptsDir + "/review_pr_system.md"
        let firstPath = Self.promptsDir + "/review_pr_first.md"
        try? Self.reviewPRSystemPrompt.write(toFile: sysPath,   atomically: true, encoding: .utf8)
        try? Self.reviewPRFirstMessage.write(toFile: firstPath, atomically: true, encoding: .utf8)
        let insertIdx = agents.filter { $0.isBuiltIn }.count
        agents.insert(AgentItem(
            name: "GitHub PR Review Agent",
            description: "Reviews a checked-out PR via gh CLI",
            instructionsPath: sysPath,
            firstMessagePath: firstPath,
            runInTempDir: false,
            isBuiltIn: true,
            syncedSystemPrompt: Self.reviewPRSystemPrompt,
            syncedFirstMessage: Self.reviewPRFirstMessage
        ), at: insertIdx)
        save()
    }
}
