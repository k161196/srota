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
    private var savedData: Data? = nil

    private static let agentsPath  = NSHomeDirectory() + "/\(Srota.dir)/agents.json"
    private static let promptsDir  = NSHomeDirectory() + "/\(Srota.dir)/agent-prompts"

    // Default prompts for built-in agents (used by "Reset to default")
    static let reviewIssueSystemPrompt = """
You are a GitHub Issue Agent with full access to the `gh` CLI, running inside a worktree already checked out to branch `issue/<number>`.

Start by reading the issue for context:
- `gh issue view <number> --json title,body,author,labels,state,url`

Work the issue in this worktree, then report back:
- `gh issue comment <number>` to post progress/results
- `gh issue edit <number>` to update title/body/labels/assignees
- `gh issue close <number>` once resolved (confirm with the user first)

Always confirm destructive or irreversible actions before executing.
"""

    static let reviewIssueFirstMessage = "Work on this issue."

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
        savedData = data
    }

    func save() {
        let dir = NSHomeDirectory() + "/\(Srota.dir)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(agents) else { return }
        guard data != savedData else { return }
        do {
            try data.write(to: URL(fileURLWithPath: Self.agentsPath))
            savedData = data
        } catch {}
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
        if fileContents(at: path, matches: text) { return }
        do { try text.write(toFile: path, atomically: true, encoding: .utf8) } catch {}
    }

    func saveFirstMessage(_ text: String, to path: String) {
        if fileContents(at: path, matches: text) { return }
        do { try text.write(toFile: path, atomically: true, encoding: .utf8) } catch {}
    }

    private func fileContents(at path: String, matches text: String) -> Bool {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber else {
            return false
        }
        guard size.intValue == text.utf8.count else { return false }
        return (try? String(contentsOfFile: path, encoding: .utf8)) == text
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
        case "GitHub Issue Agent":      return (reviewIssueSystemPrompt, reviewIssueFirstMessage)
        case "GitHub PR Review Agent":  return (reviewPRSystemPrompt, reviewPRFirstMessage)
        default:                        return (nil, "")
        }
    }

    // Ensures built-in agents always exist, even after JSON corruption or first launch
    private func loadEnsureBuiltIns() {
        load()
        // Retire the old org/feature-scoped Issues Workflow agents — superseded by
        // per-repo live GitHub issues, no local bookkeeping.
        agents.removeAll { $0.isBuiltIn && ($0.name == "Github Issues Agent" || $0.name == "Jira Issues Agent") }
        try? FileManager.default.createDirectory(atPath: Self.promptsDir, withIntermediateDirectories: true)
        if !agents.contains(where: { $0.name == "GitHub Issue Agent" && $0.isBuiltIn }) {
            seedReviewIssue()
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

    private func seedReviewIssue() {
        let sysPath   = Self.promptsDir + "/review_issue_system.md"
        let firstPath = Self.promptsDir + "/review_issue_first.md"
        try? Self.reviewIssueSystemPrompt.write(toFile: sysPath,   atomically: true, encoding: .utf8)
        try? Self.reviewIssueFirstMessage.write(toFile: firstPath, atomically: true, encoding: .utf8)
        agents.insert(AgentItem(
            name: "GitHub Issue Agent",
            description: "Works a checked-out issue via gh CLI",
            instructionsPath: sysPath,
            firstMessagePath: firstPath,
            runInTempDir: false,
            isBuiltIn: true,
            syncedSystemPrompt: Self.reviewIssueSystemPrompt,
            syncedFirstMessage: Self.reviewIssueFirstMessage
        ), at: 0)
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
