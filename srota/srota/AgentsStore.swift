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
}

@Observable @MainActor
final class AgentsStore {
    var agents: [AgentItem] = []

    private static let agentsPath  = NSHomeDirectory() + "/\(Srota.dir)/agents.json"
    private static let promptsDir  = NSHomeDirectory() + "/\(Srota.dir)/agent-prompts"

    // Default prompts for built-in agents (used by "Reset to default")
    static let githubIssuesSystemPrompt = """
You are a GitHub Issues Agent with full access to the `gh` CLI tool.

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
"""

    static let githubIssuesFirstMessage = "Hello! What would you like to do with GitHub issues today?"

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
        guard agent.isBuiltIn else { return }
        // Only github issues agent is built-in for now
        saveSystemPrompt(Self.githubIssuesSystemPrompt, to: agent.instructionsPath)
        if let path = agent.firstMessagePath {
            saveFirstMessage(Self.githubIssuesFirstMessage, to: path)
        }
    }

    // Ensures built-in agents always exist, even after JSON corruption or first launch
    private func loadEnsureBuiltIns() {
        load()
        if !agents.contains(where: { $0.isBuiltIn }) {
            seedBuiltIns()
        }
    }

    private func seedBuiltIns() {
        try? FileManager.default.createDirectory(atPath: Self.promptsDir, withIntermediateDirectories: true)
        let sysPath   = Self.promptsDir + "/github_issues_system.md"
        let firstPath = Self.promptsDir + "/github_issues_first.md"
        try? Self.githubIssuesSystemPrompt.write(toFile: sysPath,   atomically: true, encoding: .utf8)
        try? Self.githubIssuesFirstMessage.write(toFile: firstPath, atomically: true, encoding: .utf8)
        let github = AgentItem(
            name: "Github Issues Agent",
            description: "Manage GitHub issues via gh CLI",
            instructionsPath: sysPath,
            firstMessagePath: firstPath,
            runInTempDir: false,
            isBuiltIn: true
        )
        // Prepend so built-ins always appear first
        agents.insert(github, at: 0)
        save()
    }
}
