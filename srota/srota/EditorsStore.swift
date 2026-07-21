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
        markUsed(editor)
        runShell(Self.openCommand(editor, path: path))
    }

    /// Opens `path`, jumping to `line` (and optional column) when it's given and the editor's
    /// command is one of the CLI editors we know the line-jump syntax for; otherwise just opens
    /// the file. Used by the terminal's clickable file links (with or without a line reference).
    func openAtLine(_ editor: EditorItem, path: String, line: Int?, column: Int? = nil) {
        markUsed(editor)
        runShell(Self.openAtLineCommand(editor, path: path, line: line, column: column))
    }

    private func markUsed(_ editor: EditorItem) {
        lastUsedID = editor.id
        save()
    }

    private static func openCommand(_ editor: EditorItem, path: String) -> String {
        "cd '\(shellEscape(path))' && \(editor.command)"
    }

    private static func openAtLineCommand(_ editor: EditorItem, path: String, line: Int?, column: Int?) -> String {
        let escaped = shellEscape(path)
        let key = editor.command
            .split(separator: " ").first.map(String.init)
            .map { ($0 as NSString).lastPathComponent.lowercased() } ?? ""
        return line.flatMap { lineJumpFormats[key]?(editor.command, escaped, $0, column) } ?? "\(editor.command) '\(escaped)'"
    }

    private static func shellEscape(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    private func runShell(_ command: String) {
        let task = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        task.executableURL = URL(fileURLWithPath: shell)
        task.arguments = ["-i", "-l", "-c", command]
        try? task.run()
    }

    /// Line-jump argument syntax per known CLI editor, keyed by the command's base name.
    /// `bin` is always the editor's full configured command (e.g. "/usr/local/bin/code --wait"),
    /// not just the recognized name — the key only selects which syntax to use, never what to
    /// invoke, so any flags or an absolute path the user configured are preserved.
    /// Unrecognized editors fall back to opening the bare file (no line jump) in `openAtLine`.
    private static let lineJumpFormats: [String: (String, String, Int, Int?) -> String] = [
        "code": goto, "cursor": goto, "codium": goto, "code-insiders": goto,
        "zed": inline, "subl": inline, "atom": inline,
        "vim": plusLine, "nvim": plusLine, "mvim": plusLine,
        "idea": lineFlag, "webstorm": lineFlag, "pycharm": lineFlag, "xed": lineFlag,
    ]

    private static func goto(_ bin: String, _ path: String, _ line: Int, _ col: Int?) -> String {
        "\(bin) --goto '\(path)':\(line)\(col.map { ":\($0)" } ?? "")"
    }

    private static func inline(_ bin: String, _ path: String, _ line: Int, _ col: Int?) -> String {
        "\(bin) '\(path):\(line)\(col.map { ":\($0)" } ?? "")'"
    }

    private static func plusLine(_ bin: String, _ path: String, _ line: Int, _ col: Int?) -> String {
        "\(bin) +\(line) '\(path)'"
    }

    private static func lineFlag(_ bin: String, _ path: String, _ line: Int, _ col: Int?) -> String {
        "\(bin) --line \(line) '\(path)'"
    }

    #if DEBUG
    /// Runnable regression check for command generation — no XCTest target exists in this
    /// project, so this asserts on every debug launch instead (see srotaApp.init()). Only
    /// covers pure string-building (openCommand/openAtLineCommand); never calls runShell.
    static func runSelfCheck() {
        let code = EditorItem(name: "VS Code", command: "code")
        let vim = EditorItem(name: "Vim", command: "vim")
        let subl = EditorItem(name: "Sublime", command: "subl")
        let idea = EditorItem(name: "IntelliJ", command: "idea")
        let custom = EditorItem(name: "Custom", command: "z")

        assert(openCommand(code, path: "/a/b") == "cd '/a/b' && code")
        assert(openCommand(code, path: "/a/b's") == "cd '/a/b'\\''s' && code")

        // One format family per bucket: --goto, inline "path:line:col", "+line", "--line".
        assert(openAtLineCommand(code, path: "/a/b.swift", line: 143, column: 5) == "code --goto '/a/b.swift':143:5")
        assert(openAtLineCommand(code, path: "/a/b.swift", line: 143, column: nil) == "code --goto '/a/b.swift':143")
        assert(openAtLineCommand(subl, path: "/a/b.swift", line: 143, column: 5) == "subl '/a/b.swift:143:5'")
        assert(openAtLineCommand(vim, path: "/a/b.swift", line: 143, column: 5) == "vim +143 '/a/b.swift'")
        assert(openAtLineCommand(idea, path: "/a/b.swift", line: 143, column: 5) == "idea --line 143 '/a/b.swift'")

        // Dispatch key is the command's base name, lowercased — "/usr/local/bin/Code --wait"
        // resolves to the same "code" formatter as a bare "code".
        let codeWithArgs = EditorItem(name: "VS Code (wait)", command: "/usr/local/bin/Code --wait")
        assert(openAtLineCommand(codeWithArgs, path: "/a/b.swift", line: 143, column: nil)
               == "/usr/local/bin/Code --wait --goto '/a/b.swift':143")

        // No-line regression: an unrecognized editor, or a link with no line at all, falls
        // back to a bare "command '<path>'" — never a cd-based invocation.
        assert(openAtLineCommand(custom, path: "/a/b.swift", line: 143, column: nil) == "z '/a/b.swift'")
        assert(openAtLineCommand(code, path: "/a/b.swift", line: nil, column: nil) == "code '/a/b.swift'")
    }
    #endif
}
