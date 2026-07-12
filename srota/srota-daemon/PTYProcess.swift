import Darwin
import Foundation

// ponytail: forkpty deprecated macOS 14+ but still works — upgrade to posix_openpt if needed
func ptyEnvironment(
    parent: [String: String] = ProcessInfo.processInfo.environment,
    overrides env: [String: String],
    stableID: String,
    srotaDir: String
) -> [String: String] {
    var mergedEnv = parent
    for (k, v) in env {
        mergedEnv[k] = v
    }
    mergedEnv["SROTA_PANE_ID"] = stableID
    mergedEnv["SROTA_SOCKET_PATH"] = parent["SROTA_SOCKET_PATH"]
        ?? "\(NSHomeDirectory())/\(srotaDir)/daemon.sock"
    let existingPath = mergedEnv["PATH"] ?? ""
    let pathParts = [
        "\(NSHomeDirectory())/.local/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ] + existingPath.split(separator: ":").map(String.init)
    mergedEnv["PATH"] = pathParts.joined(separator: ":")
    let ghosttyTerminfo = "/Applications/Ghostty.app/Contents/Resources/terminfo"
    let hasGhosttyTerminfo = FileManager.default.fileExists(atPath: "\(ghosttyTerminfo)/78/xterm-ghostty")
    if env["TERMINFO"] == nil, hasGhosttyTerminfo { mergedEnv["TERMINFO"] = ghosttyTerminfo }
    if env["TERM"] == nil { mergedEnv["TERM"] = hasGhosttyTerminfo ? "xterm-ghostty" : "xterm-256color" }
    if env["TERM_PROGRAM"] == nil { mergedEnv["TERM_PROGRAM"] = "ghostty" }
    if env["COLORTERM"] == nil { mergedEnv["COLORTERM"] = "truecolor" }
    if mergedEnv["LANG"] == nil && mergedEnv["LC_CTYPE"] == nil { mergedEnv["LC_CTYPE"] = "en_US.UTF-8" }
    return mergedEnv
}

final class PTYProcess {
    let paneID: String
    let stableID: String
    let initialCWD: String

    private(set) var pid: pid_t = -1
    private(set) var exitCode: Int32?

    private var masterFD: Int32 = -1
    private let ring = RingBuffer()
    private var subscribers: [ClientSession] = []
    private let lock = NSLock()
    private var readSource: DispatchSourceRead?
    private var agentStatus: String?
    private var agentName: String?
    private var agentSummary: String?
    private var agentUpdatedAt: Double?
    private var agentSessionID: String?
    private var polledAgentChildPID: pid_t?
    private var polledAgentChildName: String?

    var info: PTYInfo {
        lock.lock()
        defer { lock.unlock() }
        return PTYInfo(
            paneID: paneID,
            stableID: stableID,
            pid: pid,
            cwd: initialCWD,
            exitCode: exitCode,
            agentStatus: agentStatus,
            agent: agentName,
            agentSummary: agentSummary,
            agentUpdatedAt: agentUpdatedAt,
            agentSessionID: agentSessionID
        )
    }

    init(paneID: String, stableID: String, cmd: [String], cwd: String, env: [String: String], cols: UInt16? = nil, rows: UInt16? = nil) throws {
        self.paneID = paneID
        self.stableID = stableID
        self.initialCWD = cwd
        try spawn(cmd: cmd, cwd: cwd, env: env, cols: cols, rows: rows)
    }

    // MARK: - Spawn

    private func spawn(cmd: [String], cwd: String, env: [String: String], cols: UInt16? = nil, rows: UInt16? = nil) throws {
        var newMasterFD: Int32 = -1

        let mergedEnv = ptyEnvironment(overrides: env, stableID: stableID, srotaDir: srotaDir)

        let shell = cmd.isEmpty ? [ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"] : cmd
        let argv = shell.map { strdup($0) } + [nil]
        defer {
            for ptr in argv where ptr != nil {
                free(ptr)
            }
        }

        let envp = mergedEnv.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for ptr in envp where ptr != nil {
                free(ptr)
            }
        }

        var ws = winsize()
        ws.ws_col = cols ?? 80
        ws.ws_row = rows ?? 24
        let childPID = forkpty(&newMasterFD, nil, nil, &ws)
        if childPID < 0 {
            throw NSError(domain: "PTY", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "forkpty failed"])
        }

        // Kernel-echo off: the terminal engine answers OSC/DSR queries (bg color, cursor
        // position) by writing the response back through this same fd. With ECHO on (the
        // forkpty default before the child sets its own raw mode), that write loops straight
        // back into the read side and shows up as literal garbage in the pane.
        var attrs = termios()
        if tcgetattr(newMasterFD, &attrs) == 0 {
            attrs.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(newMasterFD, TCSANOW, &attrs)
        }

        if childPID == 0 {
            _ = chdir(cwd)
            execve(argv[0], argv, envp)
            _exit(127)
        }

        pid = childPID
        masterFD = newMasterFD
        startReadLoop()
    }

    // MARK: - Read loop

    private func startReadLoop() {
        let src = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global())
        src.setEventHandler { [weak self] in self?.handleOutput() }
        src.setCancelHandler { [masterFD] in
            if masterFD >= 0 {
                Darwin.close(masterFD)
            }
        }
        src.resume()
        readSource = src
    }

    private func handleOutput() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(masterFD, &buf, buf.count)
        guard n > 0 else {
            readSource?.cancel()
            return
        }

        let data = Data(buf[..<n])
        let encoded = data.base64EncodedString()

        lock.lock()
        ring.write(data)
        let subs = subscribers
        lock.unlock()

        for client in subs {
            client.send(.live(paneID: paneID, data: encoded))
        }
    }

    // MARK: - Public interface

    // Register before replay so no bytes fall through the gap.
    func attach(client: ClientSession) {
        lock.lock()
        if !subscribers.contains(where: { $0 === client }) {
            subscribers.append(client)
        }
        let snapshot = ring.readAll()
        lock.unlock()

        var offset = 0
        while offset < snapshot.count {
            let end = min(offset + 4096, snapshot.count)
            let chunk = Data(snapshot[offset..<end])
            client.send(.ringBuffer(paneID: paneID, data: chunk.base64EncodedString()))
            offset = end
        }
        client.send(.ringBufferDone(paneID: paneID))
    }

    func removeSubscriber(_ client: ClientSession) {
        lock.lock()
        subscribers.removeAll { $0 === client }
        lock.unlock()
    }

    func applyAgentEvent(_ event: AgentEventParams) -> AgentStatusPayload? {
        guard let status = Self.status(for: event.event) else { return nil }
        let timestamp = event.timestamp ?? Date().timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        if let current = agentUpdatedAt, timestamp < current { return nil }
        agentStatus = status
        agentName = event.agent ?? "agent"
        agentSummary = event.summary ?? ""
        agentUpdatedAt = timestamp
        agentSessionID = event.sessionID ?? agentSessionID
        return AgentStatusPayload(
            paneID: paneID,
            stableID: stableID,
            status: agentStatus,
            agent: agentName,
            summary: agentSummary,
            updatedAt: agentUpdatedAt,
            sessionID: agentSessionID,
            hookEvent: event.event
        )
    }

    // Fallback for when the CLI's own hooks never fire (killed, crashed, or — as with a custom
    // CODEX_HOME profile like codex-work/codex-personal — never configured), independent of
    // hooks/notify.sh. Runs off the daemon's existing 1s reaper timer. Walks the shell's full
    // descendant tree, not just direct children: `codex` is a node shebang shim that spawns
    // (not execs) the real native "codex" binary as its own child, so that binary sits one level
    // below the shell. Can't tell codex-work/codex-personal apart from codex (all end up spawning
    // the same "codex" binary) — only detects that *an* agent is running, which is all this is used for.
    private static let knownAgentBinaries: Set<String> = ["claude", "codex"]
    private static let maxDescendantDepth = 4

    func pollAgentChild() -> AgentStatusPayload? {
        let matched = Self.listDescendantPIDs(of: pid).lazy.compactMap { childPID -> (pid_t, String)? in
            guard let path = Self.execPath(of: childPID) else { return nil }
            let name = (path as NSString).lastPathComponent
            return Self.knownAgentBinaries.contains(name) ? (childPID, name) : nil
        }.first

        lock.lock()
        let previousPID = polledAgentChildPID
        let previousName = polledAgentChildName
        lock.unlock()

        if let (childPID, name) = matched {
            guard childPID != previousPID else { return nil }
            lock.lock()
            polledAgentChildPID = childPID
            polledAgentChildName = name
            lock.unlock()
            return applyAgentEvent(AgentEventParams(stableID: stableID, event: "SessionStart", agent: name, summary: nil, timestamp: nil, sessionID: nil))
        } else if previousPID != nil {
            lock.lock()
            polledAgentChildPID = nil
            polledAgentChildName = nil
            lock.unlock()
            return applyAgentEvent(AgentEventParams(stableID: stableID, event: "SessionEnd", agent: previousName, summary: nil, timestamp: nil, sessionID: nil))
        }
        return nil
    }

    // proc_listchildpids only succeeds when the caller IS the target's direct parent — fine for
    // the daemon's own forked shell (depth 1), but it silently returns nothing when asked for a
    // grandchild's children (e.g. the shell's "node" child isn't the daemon's child). Walk the
    // system-wide process table instead (same mechanism `ps`/`pgrep` use), which has no such
    // ancestry restriction.
    private static func listChildPIDs(of pid: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).filter { $0.kp_eproc.e_ppid == pid }.map { $0.kp_proc.p_pid }
    }

    // BFS over descendants (children, grandchildren, ...) up to maxDescendantDepth — a shebang
    // shim (env -> node -> real binary) can put the process we care about several levels down.
    private static func listDescendantPIDs(of pid: pid_t, maxDepth: Int = maxDescendantDepth) -> [pid_t] {
        var result: [pid_t] = []
        var frontier = [pid]
        for _ in 0..<maxDepth {
            let children = frontier.flatMap { listChildPIDs(of: $0) }
            guard !children.isEmpty else { break }
            result.append(contentsOf: children)
            frontier = children
        }
        return result
    }

    // ponytail: PROC_PIDPATHINFO_MAXSIZE macro isn't importable into Swift — 4*MAXPATHLEN(1024) per proc_info.h
    private static func execPath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    func write(_ data: Data) {
        _ = writeAll(fd: masterFD, data: data)
    }

    func resize(rows: UInt16, cols: UInt16) {
        var ws = winsize()
        ws.ws_row = rows
        ws.ws_col = cols
        ws.ws_xpixel = 0
        ws.ws_ypixel = 0
        _ = Darwin.ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    func markExited(code: Int32) {
        lock.lock()
        exitCode = code
        let subs = subscribers
        lock.unlock()

        for client in subs {
            client.send(.dead(paneID: paneID, exitCode: code))
        }
        readSource?.cancel()
    }

    var exists: Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    @discardableResult
    func terminate() -> Bool {
        guard pid > 0 else { return false }
        guard Darwin.kill(pid, SIGTERM) == 0 else {
            if errno == ESRCH { readSource?.cancel() }
            return errno != ESRCH
        }
        readSource?.cancel()
        return true
    }

    private static func status(for event: String) -> String? {
        switch event {
        case "Start":
            return "working"
        case "SessionStart":
            return "idle"
        case "PermissionRequest":
            return "blocked"
        case "Stop":
            return "idle"
        case "SessionEnd":
            return "done"
        default:
            return nil
        }
    }
}

@discardableResult
private func writeAll(fd: Int32, data: Data) -> Bool {
    var offset = 0
    while offset < data.count {
        let wrote = data.withUnsafeBytes { rawBytes -> Int in
            let base = rawBytes.baseAddress!.advanced(by: offset)
            return Darwin.write(fd, base, data.count - offset)
        }
        if wrote > 0 {
            offset += wrote
            continue
        }
        if wrote == -1 && errno == EINTR {
            continue
        }
        return false
    }
    return true
}
