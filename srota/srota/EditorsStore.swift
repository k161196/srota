import Foundation
import Observation

/// A user-defined "open with" command, e.g. name: "VS Code", command: "code".
/// Runs as `<command> '<path>'` against a pane's current working directory.
struct EditorItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var command: String
}

private struct EditorsData: Codable {
    var editors: [EditorItem] = []
    var lastUsedID: UUID? = nil
}

@Observable @MainActor
final class EditorsStore {
    var editors: [EditorItem] = []
    var lastUsedID: UUID? = nil

    /// The editor a bare click on the Open button should launch.
    var defaultEditor: EditorItem? {
        editors.first { $0.id == lastUsedID } ?? editors.first
    }

    private static let path = NSHomeDirectory() + "/\(Srota.dir)/editors.json"

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.path)) else { return }
        if let decoded = try? JSONDecoder().decode(EditorsData.self, from: data) {
            editors = decoded.editors
            lastUsedID = decoded.lastUsedID
        } else if let legacy = try? JSONDecoder().decode([EditorItem].self, from: data) {
            editors = legacy
        }
    }

    func save() {
        let dir = NSHomeDirectory() + "/\(Srota.dir)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(EditorsData(editors: editors, lastUsedID: lastUsedID)) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.path))
    }

    func add(_ editor: EditorItem) {
        editors.append(editor)
        save()
    }

    func update(_ editor: EditorItem) {
        guard let idx = editors.firstIndex(where: { $0.id == editor.id }) else { return }
        editors[idx] = editor
        save()
    }

    func delete(id: UUID) {
        editors.removeAll { $0.id == id }
        if lastUsedID == id { lastUsedID = nil }
        save()
    }

    /// Fire-and-forget: run the editor's command against `path`, e.g. `code '<path>'`.
    /// Uses an interactive login shell so aliases/functions from the user's rc file
    /// (e.g. zoxide's `z`) resolve the same way they would in a real terminal.
    /// Remembers `editor` as the default for the next bare click.
    func open(_ editor: EditorItem, at path: String) {
        lastUsedID = editor.id
        save()
        let task = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        task.executableURL = URL(fileURLWithPath: shell)
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        task.arguments = ["-i", "-l", "-c", "cd '\(escaped)' && \(editor.command)"]
        try? task.run()
    }
}
