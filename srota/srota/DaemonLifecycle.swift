import Foundation

#if DEBUG
let daemonLabel = "com.kiran.srota.daemon-debug"
#else
let daemonLabel = "com.kiran.srota.daemon"
#endif

/// Writes the LaunchAgent plist and bootstraps it if needed. Safe to call on every launch.
func installDaemonLaunchAgent() {
    guard let binaryPath = findDaemonBinary() else { return }

    let home = NSHomeDirectory()
    let socketPath = "\(home)/\(Srota.dir)/daemon.sock"
    let logPath    = "\(home)/\(Srota.dir)/daemon.log"
    let plistPath  = "\(home)/Library/LaunchAgents/\(daemonLabel).plist"
    let binaryStamp = ((try? FileManager.default.attributesOfItem(atPath: binaryPath)[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970

    let plist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>\(daemonLabel)</string>
    <key>ProgramArguments</key>
    <array>
        <string>\(binaryPath)</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>SROTA_SOCKET_PATH</key>
        <string>\(socketPath)</string>
        <key>SROTA_DIR</key>
        <string>\(Srota.dir)</string>
        <key>SROTA_DAEMON_BINARY_STAMP</key>
        <string>\(binaryStamp)</string>
    </dict>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>\(logPath)</string>
    <key>StandardErrorPath</key>
    <string>\(logPath)</string>
</dict>
</plist>
"""

    let existing = try? String(contentsOfFile: plistPath, encoding: .utf8)
    if existing != plist {
        try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        // Re-bootstrap whenever the plist changes (new binary path, new socket path, etc.)
        let domain = "gui/\(getuid())"
        launchctl("bootout", "\(domain)/\(daemonLabel)")
        launchctl("bootstrap", domain, plistPath)
    } else {
        // Plist unchanged — make sure it's running (first launch after boot, or first install)
        let domain = "gui/\(getuid())"
        launchctl("bootstrap", domain, plistPath)
    }
}

// MARK: - Helpers

private func launchctl(_ args: String...) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = Array(args)
    try? task.run()
    task.waitUntilExit()
}

private func findDaemonBinary() -> String? {
    let fm = FileManager.default

    // Production: daemon embedded in app bundle alongside main executable
    let bundleExe = Bundle.main.executableURL?
        .deletingLastPathComponent()
        .appendingPathComponent("srota-daemon").path
    if let p = bundleExe, fm.fileExists(atPath: p) { return p }

    // Development: Xcode puts both products in the same Build/Products/Debug/ dir
    // main exe: .../Debug/srota.app/Contents/MacOS/srota
    // daemon:   .../Debug/srota-daemon
    let devPath = Bundle.main.executableURL?
        .deletingLastPathComponent()  // MacOS/
        .deletingLastPathComponent()  // Contents/
        .deletingLastPathComponent()  // srota.app/
        .deletingLastPathComponent()  // Debug/
        .appendingPathComponent("srota-daemon").path
    if let p = devPath, fm.fileExists(atPath: p) { return p }

    return nil
}
