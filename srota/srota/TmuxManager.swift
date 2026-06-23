import Foundation

final class TmuxManager {
    static let shared = TmuxManager()
    private init() {}

    let execPath: String? = {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }()

    var isAvailable: Bool { execPath != nil }

    // ponytail: -L srota = isolated socket, won't collide with user's own tmux
    func sessionName(folder: String, workspace: String) -> String {
        let safe: (String) -> String = {
            $0.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        }
        return "srota__\(safe(folder))__\(safe(workspace))"
    }

    private var confArgs: [String] {
        ["-f", NSHomeDirectory() + "/.srota/tmux.conf", "-L", "srota"]
    }

    /// Write ~/.srota/tmux.conf and apply live options to running server.
    func writeConfig() {
        let path = NSHomeDirectory() + "/.srota/tmux.conf"
        let conf = """
        set -g status off
        set -g mouse on
        set -g default-terminal "xterm-256color"
        set -g allow-passthrough on
        """
        try? conf.write(toFile: path, atomically: true, encoding: .utf8)
        applyGlobalOptions()
    }

    /// Apply options to a running tmux server (covers restored sessions).
    func applyGlobalOptions() {
        guard let exec = execPath else { return }
        // ignore errors — server may not be running yet
        run(exec, confArgs + ["set-option", "-g", "status", "off"])
        run(exec, confArgs + ["set-option", "-g", "allow-passthrough", "on"])
    }

    /// Create detached session (or reuse existing); return stable tmux session ID (e.g. "$3").
    func createSession(name: String, cwd: String?) -> String? {
        guard let exec = execPath else { return nil }
        // if session already exists, just return its ID
        if run(exec, confArgs + ["has-session", "-t", name]) == 0 {
            return capture(exec, confArgs + ["display-message", "-p", "-t", name, "#{session_id}"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n").first(where: { !$0.isEmpty })
        }
        var args = confArgs + ["new-session", "-d", "-s", name, "-P", "-F", "#{session_id}"]
        if let cwd { args += ["-c", cwd] }
        let sid = capture(exec, args)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").first(where: { !$0.isEmpty })
        // ensure status bar off even if config wasn't loaded yet
        if let sid { run(exec, confArgs + ["set-option", "-t", sid, "status", "off"]) }
        return sid
    }

    /// Write launcher script that attaches by stable session ID; falls back to new-session if killed.
    func launcherScript(sessionID: String, sessionName: String, cwd: String?) -> String {
        let dir = NSHomeDirectory() + "/.srota/sessions"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let safe = sessionName.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        let scriptPath = dir + "/\(safe).sh"
        let cwdArg = cwd.map { " -c \"\($0)\"" } ?? ""
        let tmux = "\(execPath!) -f \"$HOME/.srota/tmux.conf\" -L srota"
        // single-quote sessionID so $3-style tmux IDs aren't shell-expanded
        let content = """
        #!/bin/sh
        export ZDOTDIR="$HOME/.srota"
        if \(tmux) has-session -t '\(sessionID)' 2>/dev/null; then
            exec \(tmux) attach-session -t '\(sessionID)'
        else
            exec \(tmux) new-session -s '\(sessionName)'\(cwdArg)
        fi
        """
        try? content.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return scriptPath
    }

    /// Detach all clients from session — session + running processes stay alive.
    func detach(sessionID: String) {
        guard let exec = execPath else { return }
        _ = run(exec, confArgs + ["detach-client", "-s", sessionID])
    }

    /// Current working directory of a tmux session (from pane_current_path).
    func currentPath(sessionID: String) -> String? {
        guard let exec = execPath else { return nil }
        let out = capture(exec, confArgs + ["display-message", "-p", "-t", sessionID, "#{pane_current_path}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// Kill session entirely — terminates all processes inside it.
    func killSession(id: String) {
        guard let exec = execPath else { return }
        _ = run(exec, confArgs + ["kill-session", "-t", id])
    }

    /// Set of all live session IDs in our srota tmux server.
    func liveSessionIDs() -> Set<String> {
        guard let exec = execPath else { return [] }
        return Set(capture(exec, confArgs + ["ls", "-F", "#{session_id}"])
            .components(separatedBy: "\n").filter { !$0.isEmpty })
    }

    func listSessions() -> [String] {
        guard let exec = execPath else { return [] }
        return capture(exec, confArgs + ["ls", "-F", "#{session_name}"])
            .components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    @discardableResult
    private func run(_ exec: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exec)
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    private func capture(_ exec: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exec)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
