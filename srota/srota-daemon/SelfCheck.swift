import Darwin
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

    // create request without replayBufferBytes decodes to nil (keeps the 256 KB compat default)...
    let createDefault = try! decoder.decode(
        DaemonRequest.self,
        from: Data(#"{"type":"create","cmd":[],"cwd":"/tmp","stableID":"s1","env":{}}"#.utf8)
    )
    if case .create(let params) = createDefault {
        assert(params.replayBufferBytes == nil)
    } else {
        assertionFailure("expected create request")
    }

    // ...and a caller-supplied size round-trips through decoding untouched (clamping happens later, in RingBuffer).
    let createSized = try! decoder.decode(
        DaemonRequest.self,
        from: Data(#"{"type":"create","cmd":[],"cwd":"/tmp","stableID":"s2","env":{},"replayBufferBytes":2097152}"#.utf8)
    )
    if case .create(let params) = createSized {
        assert(params.replayBufferBytes == 2_097_152)
    } else {
        assertionFailure("expected create request")
    }

    assert(RingBuffer(capacity: 0).capacity == RingBuffer.minCapacity)
    assert(RingBuffer(capacity: -1).capacity == RingBuffer.minCapacity)
    assert(RingBuffer(capacity: Int.max).capacity == RingBuffer.maxCapacity)
    assert(RingBuffer(capacity: 1024 * 1024).capacity == 1024 * 1024)
    let zeroCapacityRing = RingBuffer(capacity: 0)
    zeroCapacityRing.write(Data([1, 2, 3]))
    assert(zeroCapacityRing.readAll() == Data([1, 2, 3]))

    // growIfNeeded grows an already-running PTY's buffer in place (an attach against a session
    // that pre-dates a larger request) and preserves what was already buffered...
    let growable = RingBuffer(capacity: RingBuffer.minCapacity)
    growable.write(Data([1, 2, 3]))
    growable.growIfNeeded(to: 1024 * 1024)
    assert(growable.capacity == 1024 * 1024)
    assert(growable.readAll() == Data([1, 2, 3]))
    // ...but never shrinks back down for a smaller/absent request.
    growable.growIfNeeded(to: RingBuffer.minCapacity)
    assert(growable.capacity == 1024 * 1024)

    // Same, but after the ring has actually wrapped (write count > capacity) — growIfNeeded's
    // `readAll()` must follow the wrapped read-head math, not just the unwrapped 3-byte case above.
    let wrapped = RingBuffer(capacity: RingBuffer.minCapacity)
    let overfillCount = RingBuffer.minCapacity + 5
    let overfillBytes = (0..<overfillCount).map { UInt8($0 % 256) }
    wrapped.write(Data(overfillBytes))
    let survivingBytes = Data(overfillBytes.suffix(RingBuffer.minCapacity))
    assert(wrapped.readAll() == survivingBytes) // oldest 5 bytes already overwritten, pre-growth
    wrapped.growIfNeeded(to: 2 * RingBuffer.minCapacity)
    assert(wrapped.capacity == 2 * RingBuffer.minCapacity)
    assert(wrapped.readAll() == survivingBytes) // same content, same order, after reallocation

    // attach requests round-trip replayBufferBytes same as create...
    let attachSized = try! decoder.decode(
        DaemonRequest.self,
        from: Data(#"{"type":"attach","paneID":"pane-1","replayBufferBytes":2097152}"#.utf8)
    )
    if case .attach(let paneID, let replayBufferBytes) = attachSized {
        assert(paneID == "pane-1")
        assert(replayBufferBytes == 2_097_152)
    } else {
        assertionFailure("expected attach request")
    }

    // ...and default to nil (no resize) when the caller doesn't ask for one.
    let attachDefault = try! decoder.decode(
        DaemonRequest.self,
        from: Data(#"{"type":"attach","paneID":"pane-2"}"#.utf8)
    )
    if case .attach(_, let replayBufferBytes) = attachDefault {
        assert(replayBufferBytes == nil)
    } else {
        assertionFailure("expected attach request")
    }

    // Existing-PTY attach path: re-attaching to an already-running PTY with a larger
    // replayBufferBytes must grow ITS buffer in place — the bug this fixed was resizing only
    // happening at creation, so re-attaching (the common case once a PTY outlives one attach)
    // silently kept the 256 KB default forever.
    // fds are intentionally left open, not closed: main.swift exits right after this self-check
    // returns, so the OS reclaims them — closing one end ourselves while the daemon's async
    // replay dispatch might still write to the other risks an EPIPE-driven SIGPIPE (not yet
    // ignored at this point in startup) killing the self-check instead of failing an assert.
    var fds: [Int32] = [0, 0]
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    let selfCheckRegistry = PTYRegistry()
    let selfCheckClient = ClientSession(fd: fds[0], registry: selfCheckRegistry)

    let agentPTY = try! PTYProcess(paneID: "self-check-agent", stableID: "self-check-agent", cmd: ["/bin/cat"], cwd: "/tmp", env: [:])
    defer { agentPTY.terminate() }
    assert(agentPTY.replayCapacity == 256 * 1024)
    agentPTY.attach(client: selfCheckClient, replayBufferBytes: 2 * 1024 * 1024)
    assert(agentPTY.replayCapacity == 2 * 1024 * 1024)

    // Agent/non-agent isolation: a sibling PTY that never requests a larger buffer stays at the
    // default — growth is per-PTYProcess (each owns its own RingBuffer), never global.
    let plainPTY = try! PTYProcess(paneID: "self-check-plain", stableID: "self-check-plain", cmd: ["/bin/cat"], cwd: "/tmp", env: [:])
    defer { plainPTY.terminate() }
    plainPTY.attach(client: selfCheckClient)
    assert(plainPTY.replayCapacity == 256 * 1024)

    return true
}
