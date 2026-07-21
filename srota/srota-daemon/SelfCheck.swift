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

    // sessionID round-trips through AgentEventParams when the hook payload carries one...
    let eventWithSession = try! decoder.decode(
        DaemonRequest.self,
        from: Data(#"{"type":"agent_event","stableID":"stable-1","event":"Stop","agent":"claude","summary":"done","timestamp":1.0,"sessionID":"abc-123"}"#.utf8)
    )
    if case .agentEvent(let params) = eventWithSession {
        assert(params.sessionID == "abc-123")
    } else {
        assertionFailure("expected agent_event request")
    }

    // ...and is nil, not a decode failure, when the hook payload omits it entirely (best-effort).
    let eventWithoutSession = try! decoder.decode(
        DaemonRequest.self,
        from: Data(#"{"type":"agent_event","stableID":"stable-1","event":"Stop","agent":"claude","summary":"done","timestamp":1.0}"#.utf8)
    )
    if case .agentEvent(let params) = eventWithoutSession {
        assert(params.sessionID == nil)
    } else {
        assertionFailure("expected agent_event request")
    }

    // AgentStatusPayload.sessionID and hookEvent encode onto the wire when present...
    let statusData = try! JSONEncoder().encode(.agentStatus(AgentStatusPayload(
        paneID: "pane-1", stableID: "stable-1", status: "idle", agent: "claude",
        summary: "done", updatedAt: 1.0, sessionID: "abc-123", hookEvent: "Stop"
    )) as DaemonResponse)
    let status = try! JSONSerialization.jsonObject(with: statusData) as! [String: Any]
    assert(status["sessionID"] as? String == "abc-123")
    assert(status["hookEvent"] as? String == "Stop")

    // ...and are simply absent from the wire (not a null placeholder) when nil — status alone
    // can't distinguish "Stop" from "SessionStart" (both collapse to "idle"), which is exactly
    // why hookEvent exists: it must survive the round trip distinctly from status.
    let statusNoSessionData = try! JSONEncoder().encode(.agentStatus(AgentStatusPayload(
        paneID: "pane-1", stableID: "stable-1", status: "idle", agent: "claude",
        summary: "done", updatedAt: 1.0, sessionID: nil, hookEvent: nil
    )) as DaemonResponse)
    let statusNoSession = try! JSONSerialization.jsonObject(with: statusNoSessionData) as! [String: Any]
    assert(statusNoSession["sessionID"] == nil)
    assert(statusNoSession["hookEvent"] == nil)

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

    assert(RingBuffer(capacity: 0).capacity == RingBuffer.minCapacity)
    assert(RingBuffer(capacity: -1).capacity == RingBuffer.minCapacity)
    assert(RingBuffer(capacity: Int.max).capacity == RingBuffer.maxCapacity)
    assert(RingBuffer(capacity: 1024 * 1024).capacity == 1024 * 1024)
    let zeroCapacityRing = RingBuffer(capacity: 0)
    zeroCapacityRing.write(Data([1, 2, 3]))
    assert(zeroCapacityRing.readAll() == Data([1, 2, 3]))

    return true
}
