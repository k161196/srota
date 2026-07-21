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
    private var savedData: Data? = nil

    /// The editor a bare click on the Open button should launch.
    var defaultEditor: EditorItem? {
        editors.first { $0.id == lastUsedID } ?? editors.first
    }

    private static let path = NSHomeDirectory() + "/\(Srota.dir)/editors.json"

    /// Set once at app launch. Lets code outside the SwiftUI environment (the terminal's
    /// cmd-click link handler, which runs from a Ghostty delegate callback, not a View) reach
    /// the same store the "Open" button uses.
    private(set) static var shared: EditorsStore?

    init() {
        load()
        Self.shared = self
    }

    func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.path)) else { return }
        savedData = data
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
        guard data != savedData else { return }
        do {
            try data.write(to: URL(fileURLWithPath: Self.path))
            savedData = data
        } catch {}
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
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        runShell("cd '\(escaped)' && \(editor.command)")
    }

    /// Opens `path` at a specific line (and optional column) when the editor's command is one
    /// of the CLI editors we know the line-jump syntax for; otherwise just opens the file.
    /// Used by the terminal's clickable file:line links.
    func openAtLine(_ editor: EditorItem, path: String, line: Int, column: Int? = nil) {
        lastUsedID = editor.id
        save()
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        let key = editor.command
            .split(separator: " ").first.map(String.init)
            .map { ($0 as NSString).lastPathComponent.lowercased() } ?? ""
        let command = Self.lineJumpFormats[key]?(escaped, line, column) ?? "\(editor.command) '\(escaped)'"
        runShell(command)
    }

    private func runShell(_ command: String) {
        let task = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-i", "-l", "-c", command]
        try? task.run()
    }

    /// Line-jump argument syntax per known CLI editor, keyed by the command's base name.
    /// Unrecognized editors fall back to opening the bare file (no line jump) in `openAtLine`.
    private static let lineJumpFormats: [String: (String, Int, Int?) -> String] = [
        "code": goto("code"), "cursor": goto("cursor"), "codium": goto("codium"), "code-insiders": goto("code-insiders"),
        "zed": inline("zed"), "subl": inline("subl"), "atom": inline("atom"),
        "vim": plusLine("vim"), "nvim": plusLine("nvim"), "mvim": plusLine("mvim"),
        "idea": lineFlag("idea"), "webstorm": lineFlag("webstorm"), "pycharm": lineFlag("pycharm"), "xed": lineFlag("xed"),
    ]

    private static func goto(_ bin: String) -> (String, Int, Int?) -> String {
        { path, line, col in "\(bin) --goto '\(path)':\(line)\(col.map { ":\($0)" } ?? "")" }
    }

    private static func inline(_ bin: String) -> (String, Int, Int?) -> String {
        { path, line, col in "\(bin) '\(path):\(line)\(col.map { ":\($0)" } ?? "")'" }
    }

    private static func plusLine(_ bin: String) -> (String, Int, Int?) -> String {
        { path, line, _ in "\(bin) +\(line) '\(path)'" }
    }

    private static func lineFlag(_ bin: String) -> (String, Int, Int?) -> String {
        { path, line, _ in "\(bin) --line \(line) '\(path)'" }
    }
}
