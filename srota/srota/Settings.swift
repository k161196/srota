import Foundation
import Observation

#if DEBUG
enum Srota { nonisolated static let dir = ".srota-debug" }
#else
enum Srota { nonisolated static let dir = ".srota" }
#endif

@Observable @MainActor
final class AppSettings {
    var baseWorkingDirectory: String?
    var mcpServerPath: String?
    var shortcutPrefix: String = "ctrl+b"

    private static let path = NSHomeDirectory() + "/\(Srota.dir)/settings.toml"

    init() { load() }

    private func load() {
        guard let text = try? String(contentsOfFile: Self.path, encoding: .utf8) else { return }
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: " = ")
            guard parts.count >= 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            var val = parts.dropFirst().joined(separator: " = ").trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") { val = String(val.dropFirst().dropLast()) }
            if key == "base_working_directory" { baseWorkingDirectory = val }
            if key == "mcp_server_path" { mcpServerPath = val }
            if key == "shortcut_prefix" { shortcutPrefix = val }
        }
    }

    /// Explicit override → installed ~/.srota/srota-mcp/ → dev source fallback.
    var resolvedMCPServerPath: String? {
        if let p = mcpServerPath, !p.isEmpty { return p }
        let fm = FileManager.default
        let installed = NSHomeDirectory() + "/\(Srota.dir)/srota-mcp/index.ts"
        if fm.fileExists(atPath: installed) { return installed }
        // Dev: walk up from source file to repo root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let devPath = root.appendingPathComponent("scripts/srota-mcp/index.ts").path
        return fm.fileExists(atPath: devPath) ? devPath : nil
    }

    func save() {
        let dir = NSHomeDirectory() + "/\(Srota.dir)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var lines: [String] = []
        if let d = baseWorkingDirectory { lines.append("base_working_directory = \"\(d)\"") }
        if let m = mcpServerPath { lines.append("mcp_server_path = \"\(m)\"") }
        lines.append("shortcut_prefix = \"\(shortcutPrefix)\"")
        try? lines.joined(separator: "\n").write(toFile: Self.path, atomically: true, encoding: .utf8)
    }
}
