import SwiftUI

@main
struct srotaApp: App {
    var body: some Scene {
        WindowGroup("Srota - स्रोत") {
            ContentView()
                .preferredColorScheme(.dark)
                .onAppear { setupShellIntegration() }
        }
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
    typeset -ga precmd_functions
    (( ${precmd_functions[(I)_srota_osc7]} )) || precmd_functions+=(_srota_osc7)
    _srota_osc7
    """
    try? zshrc.write(toFile: "\(dir)/.zshrc", atomically: true, encoding: .utf8)

    let launcher = "#!/bin/sh\nexport ZDOTDIR=\"$HOME/.srota\"\nexec /bin/zsh -i \"$@\"\n"
    let launcherPath = "\(dir)/zsh-launcher.sh"
    try? launcher.write(toFile: launcherPath, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcherPath)
}
