import SwiftUI

@main
struct srotaApp: App {
    @State private var settings = AppSettings()
    @State private var db = WorkspaceDB()
    @State private var presetsStore = PresetsStore()
    @State private var editorsStore = EditorsStore()
    @State private var promptsStore = PromptsStore()
    @State private var agentsStore  = AgentsStore()
    @State private var shortcuts = KeyboardShortcutManager()
    @State private var daemonConnection = DaemonConnection()
    @State private var hookSetupResult: HookSetupResult? = nil
    // Constructed eagerly (not in onAppear) so it can be injected into the environment like
    // every other store — PaneHeader's timeline icon and SessionTimelineSidebar both read it
    // via @Environment(SessionRecorder.self).
    @State private var sessionRecorder: SessionRecorder

    init() {
        let db = WorkspaceDB()
        _db = State(initialValue: db)
        _sessionRecorder = State(initialValue: SessionRecorder(db: db))
    }

    var body: some Scene {
        WindowGroup("Srota - स्रोत") {
            ContentView()
                .preferredColorScheme(.dark)
                .environment(settings)
                .environment(db)
                .environment(presetsStore)
                .environment(editorsStore)
                .environment(promptsStore)
                .environment(agentsStore)
                .environment(shortcuts)
                .environment(daemonConnection)
                .environment(sessionRecorder)
                .onAppear {
                    shortcuts.prefixKey = settings.shortcutPrefix
                    // Cascade-delete a pane's sessions only when it's genuinely, permanently
                    // closed (closeSession/killPane) — never on ws_panes' own delete/reinsert
                    // churn from saveTabsAndPanes/saveLayoutSnapshot (ticket 07).
                    daemonConnection.onPaneClosed = { stableID in
                        Task { @MainActor in db.deleteSessions(paneID: stableID) }
                    }
                    daemonConnection.onAgentEvent = { event in
                        Task { @MainActor in sessionRecorder.handle(event) }
                    }
                    // Picks up agent-initiated notes (srota-mcp's add_session_note tool writes
                    // directly to SQLite from a separate process) live, via the same file
                    // watcher that already refreshes the repos list on any db write.
                    db.onExternalWrite = { [sessionRecorder] in sessionRecorder.refreshTrackedPanes() }
                    Task { await startHookHealthLoop() }
                    Task {
                        await Task.yield()
                        Task.detached { setupShellIntegration() }
                        Task.detached { installMCPServer() }
                        Task.detached { await installDaemonLaunchAgent() }
                    }
                    Task { await daemonConnection.connectWithRetry() }
                }
                .onChange(of: settings.shortcutPrefix) { _, new in
                    shortcuts.prefixKey = new
                }
                .sheet(item: $hookSetupResult) { result in
                    if let script = findCheckScript() {
                        HookSetupSheet(result: result, checkScriptPath: script) {
                            hookSetupResult = nil
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
    }

    // Re-checks periodically because other tools (e.g. another CLI's hook installer)
    // can silently overwrite our entries in ~/.claude/settings.json after launch —
    // the once-at-launch check alone would miss that drift for the rest of the session.
    private static var hookHealthLoopStarted = false

    private func startHookHealthLoop() async {
        guard !Self.hookHealthLoopStarted else { return }
        Self.hookHealthLoopStarted = true
        while true {
            await runHookCheck()
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    private func runHookCheck() async {
        guard let script = findCheckScript() else { return }
        guard let result = await checkAgentHooks(scriptPath: script) else { return }
        guard result.needsSetup else { return }
        await MainActor.run {
            hookSetupResult = result
        }
    }

    /// Bundled in app Resources; falls back to project scripts/ for dev builds.
    private func findCheckScript() -> String? {
        if let path = Bundle.main.path(forResource: "check-agent-hooks", ofType: "sh") {
            return path
        }
        let fileManager = FileManager.default
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("scripts/check-agent-hooks.sh"),
            sourceRoot.appendingPathComponent("scripts/check-agent-hooks.sh"),
        ]

        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            if fileManager.isExecutableFile(atPath: path) || fileManager.fileExists(atPath: path) {
                return path
            }
        }

        return nil
    }
}

/// Writes ~/.srota/.zshrc + ~/.srota/zsh-launcher.sh so every terminal
/// gets OSC 7 working-directory reporting without user setup.
nonisolated private func setupShellIntegration() {
    let home = NSHomeDirectory()
    let dir = "\(home)/\(Srota.dir)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    // Sourcing order mirrors a real interactive login shell, then appends our hook.
    let zshrc = """
    unset ZDOTDIR
    [[ -f "$HOME/.zshenv" ]] && source "$HOME/.zshenv"
    [[ -f "$HOME/.zprofile" ]] && source "$HOME/.zprofile"
    [[ -f "$HOME/.zshrc" ]] && source "$HOME/.zshrc"
_srota_osc7() { printf '\\033]7;file://%s%s\\007' "${HOSTNAME:-localhost}" "$PWD" }
_srota_export_cwd() { export SROTA_TAB_CWD="$PWD"; }
typeset -ga precmd_functions
(( ${precmd_functions[(I)_srota_osc7]} )) || precmd_functions+=(_srota_osc7)
(( ${precmd_functions[(I)_srota_export_cwd]} )) || precmd_functions+=(_srota_export_cwd)
_srota_export_cwd
_srota_osc7
"""
    try? zshrc.write(toFile: "\(dir)/.zshrc", atomically: true, encoding: .utf8)

    let launcher = "#!/bin/sh\nexport ZDOTDIR=\"$HOME/\(Srota.dir)\"\nexec /bin/zsh -i \"$@\"\n"
    let launcherPath = "\(dir)/zsh-launcher.sh"
    try? launcher.write(toFile: launcherPath, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherPath)
}

/// Copies the srota-mcp files to ~/.srota/srota-mcp/ and runs
/// `bun install` if node_modules is missing or package.json changed.
/// Source: app bundle (production) or scripts/srota-mcp/ via #filePath (dev).
nonisolated private func installMCPServer() {
    let fm = FileManager.default

    // Resolve source directory — bundle first, then dev source tree
    let bundleSrc = Bundle.main.resourceURL?.appendingPathComponent("srota-mcp")
    let devSrc = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/srota-mcp")
    guard let src = [bundleSrc, devSrc].compactMap({ $0 }).first(where: {
        fm.fileExists(atPath: $0.appendingPathComponent("index.ts").path)
    }) else { return }

    let dest = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("\(Srota.dir)/srota-mcp")
    try? fm.createDirectory(at: dest, withIntermediateDirectories: true)

    var packageChanged = false
    for file in ["index.ts", "package.json", "bun.lock"] {
        let srcFile = src.appendingPathComponent(file)
        guard fm.fileExists(atPath: srcFile.path) else { continue }
        let dstFile = dest.appendingPathComponent(file)
        if file == "package.json" {
            packageChanged = (try? Data(contentsOf: dstFile)) != (try? Data(contentsOf: srcFile))
        }
        try? fm.removeItem(at: dstFile)
        try? fm.copyItem(at: srcFile, to: dstFile)
    }

    let nodeModules = dest.appendingPathComponent("node_modules").path
    guard !fm.fileExists(atPath: nodeModules) || packageChanged else { return }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = ["bun", "install", "--frozen-lockfile"]
    task.currentDirectoryURL = dest
    try? task.run()
    task.waitUntilExit()
}
