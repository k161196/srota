import SwiftUI

@main
struct srotaApp: App {
    @State private var settings = AppSettings()
    @State private var db = WorkspaceDB()
    @State private var presetsStore = PresetsStore()
    @State private var agentFocus = FeatureAgentFocus()
    @State private var hookSetupResult: HookSetupResult? = nil

    var body: some Scene {
        WindowGroup("Srota - स्रोत") {
            ContentView()
                .preferredColorScheme(.dark)
                .environment(settings)
                .environment(db)
                .environment(presetsStore)
                .environment(agentFocus)
                .onAppear {
                    setupShellIntegration()
                    if let dir = settings.baseWorkingDirectory { db.scan(baseDir: dir) }
                    Task { await runHookCheck() }
                }
                .sheet(item: $hookSetupResult) { result in
                    if let script = findCheckScript() {
                        HookSetupSheet(result: result, checkScriptPath: script) {
                            hookSetupResult = nil
                        }
                    }
                }
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
private func setupShellIntegration() {
    let home = NSHomeDirectory()
    let dir = "\(home)/.srota"
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

    let launcher = "#!/bin/sh\nexport ZDOTDIR=\"$HOME/.srota\"\nexec /bin/zsh -i \"$@\"\n"
    let launcherPath = "\(dir)/zsh-launcher.sh"
    try? launcher.write(toFile: launcherPath, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherPath)
}
