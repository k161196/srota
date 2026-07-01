import Foundation

@discardableResult
func runDaemonSelfCheck() -> Bool {
    guard ProcessInfo.processInfo.environment["SROTA_DAEMON_SELF_CHECK"] == "1" else { return false }

    let decoder = JSONDecoder()
    let request = try! decoder.decode(
        DaemonRequest.self,
        from: Data(#"{"type":"list","requestID":"req-1"}"#.utf8)
    )
    if case .list(let requestID) = request {
        assert(requestID == "req-1")
    } else {
        assertionFailure("expected list request")
    }

    let responseData = try! JSONEncoder().encode(.created(paneID: "pane-1", requestID: "req-2") as DaemonResponse)
    let response = try! JSONSerialization.jsonObject(with: responseData) as! [String: Any]
    assert(response["paneID"] as? String == "pane-1")
    assert(response["requestID"] as? String == "req-2")

    assert(processExitCode(from: 7 << 8) == 7)
    assert(processExitCode(from: 9) == 137)

    let inheritedTerminalEnv = ptyEnvironment(
        parent: ["TERM": "tmux-256color", "TERM_PROGRAM": "tmux"],
        overrides: [:],
        stableID: "stable-1",
        srotaDir: ".srota"
    )
    let hasGhosttyTerminfo = FileManager.default.fileExists(atPath: "/Applications/Ghostty.app/Contents/Resources/terminfo/78/xterm-ghostty")
    assert(inheritedTerminalEnv["TERM"] == (hasGhosttyTerminfo ? "xterm-ghostty" : "xterm-256color"))
    if hasGhosttyTerminfo {
        assert(inheritedTerminalEnv["TERMINFO"] == "/Applications/Ghostty.app/Contents/Resources/terminfo")
    }
    assert(inheritedTerminalEnv["TERM_PROGRAM"] == "ghostty")
    assert(inheritedTerminalEnv["COLORTERM"] == "truecolor")

    let explicitTerminalEnv = ptyEnvironment(
        parent: ["TERM": "tmux-256color"],
        overrides: ["TERM": "ansi"],
        stableID: "stable-2",
        srotaDir: ".srota"
    )
    assert(explicitTerminalEnv["TERM"] == "ansi")
    return true
}
