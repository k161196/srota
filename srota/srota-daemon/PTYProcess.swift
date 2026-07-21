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

// One subscribed client, plus a serial queue that every send to that client (for this one PTY)
// goes through. The queue — not PTYProcess's own `lock` — is what makes replay-before-live
// ordering hold: attach() and handleOutput() both enqueue onto it while holding `lock` (so
// enqueue order is deterministic), but the actual blocking client.send() I/O runs later, off the
// lock, on this per-client queue. A slow/stalled reader backs up only its own queue — never
// PTYProcess's shared lock, which every other subscriber's send, resize(), write(), terminate(),
// and attach() all need briefly for bookkeeping.
final class Subscriber {
    let client: ClientSession
    let queue = DispatchQueue(label: "srota.pty.subscriber")
    private let stateLock = NSLock()
    private var valid = true
    private var pendingBytes = 0
    // Bumped by resetBudget(). Lets release() tell a reservation made before a reset apart from
    // one made after — without this, a stale pre-reset closure's release() would subtract from
    // whatever pendingBytes happens to be once new reservations refill it, silently freeing budget
    // the new reservations still legitimately own and letting tryReserve over-admit past the cap.
    private var budgetGeneration = 0
    // Bumped every time a new replay supersedes an old one. DispatchWorkItem.cancel() is purely
    // cooperative — it only sets a flag nobody reads, it does NOT stop an already-queued item from
    // running when its turn comes. A generation token, checked inside the replay closure itself
    // (including between chunks, not just once at the top), is what actually stops a superseded
    // replay from running to completion — without it, every past attach()'s full snapshot would
    // still get sent in full, defeating the point of bounding a stalled client to one replay.
    private var replayGeneration = 0
    // Counts overflows with no confirmed forward progress since the last one. A client whose
    // ClientSession.writeLock is held forever by one irrecoverably-stuck write (not merely slow —
    // permanently dead) means NOTHING enqueued for it, on any queue, will ever finish to free its
    // memory: reusing this one subscriber and capping it to one pending replay each still lets
    // every retry add another bounded (but nonzero) batch of never-executing work, forever, as
    // long as PTY output keeps arriving. This is what actually stops that: after a few consecutive
    // overflows with no proof the queue is moving again, give up and disconnect for good instead
    // of retrying indefinitely.
    private var consecutiveOverflows = 0
    static let maxConsecutiveOverflows = 3

    // Bounds how much not-yet-sent live data can pile up behind a slow/stuck client before new
    // frames start getting dropped for it instead of growing this queue's backlog (and the memory
    // each pending closure retains) without limit. Matches RingBuffer's own 256KB cap — a client
    // this far behind gets a complete, fresh picture from the ring buffer on its next attach()
    // anyway, so dropped live frames aren't a correctness problem, just a delayed live view.
    static let maxPendingBytes = 256 * 1024

    init(client: ClientSession) {
        self.client = client
    }

    // Called on disconnect (removeSubscriber) or backpressure give-up so any closures already
    // enqueued on `queue` — which still hold a strong ref to this subscriber and its client
    // regardless of the array removal — become cheap no-ops instead of writing to what may by
    // then be a closed, possibly-reused fd. isCurrentReplay() folds this in too, so an in-flight
    // replay stops at its next chunk boundary the same way a superseded one does.
    func invalidate() {
        stateLock.lock()
        valid = false
        stateLock.unlock()
    }

    var isValid: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return valid
    }

    enum ReserveResult { case reserved(generation: Int), alreadyInvalid, overflowRetry, overflowGiveUp }

    // Reserves room for `byteCount` more pending bytes before enqueueing a live send.
    // `.overflowRetry`/`.overflowGiveUp` mean this subscriber is too far behind to keep a coherent
    // stream — dropping a raw chunk could split a multi-byte character or an ANSI escape sequence,
    // silently corrupting rendering with no way for the client to tell — so the caller must
    // invalidate it rather than just skip this one frame. `.overflowGiveUp` additionally means
    // several such overflows happened with no progress in between: retrying further is very
    // unlikely to help and would just keep growing memory, so the caller must not resync, only disconnect.
    func tryReserve(_ byteCount: Int) -> ReserveResult {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard valid else { return .alreadyInvalid }
        guard pendingBytes + byteCount <= Self.maxPendingBytes else {
            consecutiveOverflows += 1
            return consecutiveOverflows > Self.maxConsecutiveOverflows ? .overflowGiveUp : .overflowRetry
        }
        pendingBytes += byteCount
        return .reserved(generation: budgetGeneration)
    }

    // `generation` must be the one returned by the tryReserve() this release corresponds to. A
    // release whose generation predates the most recent resetBudget() is a no-op: the reservation
    // it refers to was already wiped out by that reset, so applying it now would instead subtract
    // from a later generation's unrelated reservations.
    func release(_ byteCount: Int, generation: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard generation == budgetGeneration else { return }
        pendingBytes = max(0, pendingBytes - byteCount)
    }

    // Called the instant a closure actually starts running (before whatever it goes on to do) —
    // proof this subscriber's queue made forward progress, since that only happens once whatever
    // was ahead of it finished. A client that's merely occasionally slow keeps getting its full
    // retry budget back this way; only a queue that's never progressing at all runs out consecutive
    // overflows without ever hitting this.
    func recordProgress() {
        stateLock.lock()
        consecutiveOverflows = 0
        stateLock.unlock()
    }

    // Drops the live-frame budget back to 0 for a resync retry. Bumps budgetGeneration so
    // release() calls from reservations made before this reset become no-ops instead of
    // subtracting from whatever pendingBytes the next generation reserves.
    func resetBudget() {
        stateLock.lock()
        pendingBytes = 0
        budgetGeneration += 1
        stateLock.unlock()
    }

    // Starts a new replay generation and returns its token — the caller passes this into the
    // replay closure, which must check isCurrentReplay(token) before starting AND between every
    // chunk, since a later attach() bumping the generation is the only thing that actually stops
    // an earlier, already-queued (or already-running) replay from continuing.
    func beginReplay() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        replayGeneration += 1
        return replayGeneration
    }

    // False once either this subscriber is invalidated, or a newer replay has superseded `token`.
    func isCurrentReplay(_ token: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return valid && replayGeneration == token
    }
}

final class PTYProcess {
    let paneID: String
    let stableID: String
    let initialCWD: String

    private(set) var pid: pid_t = -1
    private(set) var exitCode: Int32?

    private var masterFD: Int32 = -1
    private let ring: RingBuffer
    private var subscribers: [Subscriber] = []
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

    init(
        paneID: String,
        stableID: String,
        cmd: [String],
        cwd: String,
        env: [String: String],
        cols: UInt16? = nil,
        rows: UInt16? = nil,
        replayBufferBytes: Int? = nil
    ) throws {
        self.paneID = paneID
        self.stableID = stableID
        self.initialCWD = cwd
        self.ring = RingBuffer(capacity: replayBufferBytes ?? 256 * 1024)
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
        let byteCount = encoded.utf8.count

        // ring.write, tryReserve, and queue.async are all non-blocking (bookkeeping plus
        // scheduling a block — never the actual socket write), so holding `lock` across all three
        // costs nothing here, and it's what keeps this atomic with attach()'s own snapshot+enqueue
        // below. Releasing the lock between ring.write and the enqueue (as a prior version did)
        // left a gap where attach() could slip in, snapshot the ring (now including this chunk),
        // and enqueue its replay — then this live enqueue for the SAME bytes would land right
        // after, delivering them to the client twice.
        lock.lock()
        defer { lock.unlock() }
        ring.write(data)
        // Collected instead of removed in-place — subscribers is being iterated below, and this
        // keeps the removal a single pass after the loop rather than mutating mid-iteration.
        var goneForGood: [ObjectIdentifier] = []
        var toResync: [Subscriber] = []
        for subscriber in subscribers {
            switch subscriber.tryReserve(byteCount) {
            case .reserved(let generation):
                subscriber.queue.async { [paneID] in
                    subscriber.recordProgress()
                    defer { subscriber.release(byteCount, generation: generation) }
                    guard subscriber.isValid else { return }
                    subscriber.client.send(.live(paneID: paneID, data: encoded))
                }
            case .alreadyInvalid:
                continue
            case .overflowRetry:
                // Too far behind to keep sending it a coherent stream — silently dropping this
                // chunk risks losing text or splitting a multi-byte char/ANSI escape mid-sequence,
                // corrupting rendering with no way for the client to notice. The app still
                // believes it's attached and has no reason to ever request a fresh replay on its
                // own, so leaving it detached would freeze the pane forever. Reuse THIS subscriber
                // (not a new one) with its budget reset, queued for one resync below.
                subscriber.resetBudget()
                toResync.append(subscriber)
            case .overflowGiveUp:
                // Several consecutive overflows with no progress in between (see
                // Subscriber.consecutiveOverflows) — retrying again would just add another bounded
                // but nonzero batch of work that's very unlikely to ever run, for as long as PTY
                // output keeps arriving. Stop for good instead of resyncing — and close the
                // client's whole connection (not just this one subscription): a permanently stuck
                // write means ClientSession.writeLock is jammed for every pane this client has
                // open, and merely dropping our own subscriber would leave the app believing it's
                // still attached, with nothing left to ever tell it otherwise. The app's
                // DaemonConnection detects the resulting EOF and reconnects + re-attaches every
                // pane on its own.
                subscriber.invalidate()
                goneForGood.append(ObjectIdentifier(subscriber))
                subscriber.client.disconnect()
            }
        }
        if !goneForGood.isEmpty {
            subscribers.removeAll { goneForGood.contains(ObjectIdentifier($0)) }
        }
        // Exactly one queued replay per resync, on the SAME subscriber object — if the client is
        // still stuck, this cycles again next overflow (up to maxConsecutiveOverflows) rather than
        // piling up new Subscriber/queue pairs; if it's genuinely gone, removeSubscriber (via the
        // client's own read-side disconnect detection) cleans this up like any other subscriber.
        for subscriber in toResync {
            scheduleReplay(for: subscriber, client: subscriber.client)
        }
    }

    // MARK: - Public interface

    // Register before replay so no bytes fall through the gap. The actual chunk-sending — up to
    // 256KB of blocking socket I/O — is enqueued onto this client's own serial queue instead of
    // running inline under `lock`: enqueueing while holding `lock` (matching handleOutput's own
    // hold above) is what guarantees no live message can jump ahead of replay for this client,
    // without making every other subscriber/resize/write/terminate call wait on this client's I/O.
    //
    // The replay itself isn't reserved against tryReserve's cap (a legitimate first attach against
    // a full ring needs to send all of it, regardless of the live-frame backpressure budget) — but
    // repeated attach() calls against the SAME still-stalled subscriber replace any not-yet-started
    // replay instead of queuing another one alongside it, so this can't grow memory unbounded either.
    func attach(client: ClientSession) {
        lock.lock()
        defer { lock.unlock() }
        attachLocked(client: client)
    }

    // Shared by attach() and handleOutput()'s overflow-resync path — caller must already hold `lock`.
    private func attachLocked(client: ClientSession) {
        let subscriber = subscribers.first(where: { $0.client === client }) ?? {
            let new = Subscriber(client: client)
            subscribers.append(new)
            return new
        }()
        scheduleReplay(for: subscriber, client: client)
    }

    // Builds and enqueues a fresh replay for `subscriber` — shared by attachLocked() (a real
    // app-initiated attach) and handleOutput()'s overflow-retry path (an internal resync reusing
    // the SAME subscriber instead of creating a new one). beginReplay() bumps the generation
    // immediately (while still holding `lock`), so any earlier replay for this subscriber —
    // queued, or already mid-chunk-loop — sees a stale token on its very next check and stops
    // there, instead of running to completion.
    private func scheduleReplay(for subscriber: Subscriber, client: ClientSession) {
        let snapshot = ring.readAll()
        let token = subscriber.beginReplay()
        subscriber.queue.async { [paneID] in
            subscriber.recordProgress()
            guard subscriber.isCurrentReplay(token) else { return }
            var offset = 0
            while offset < snapshot.count, subscriber.isCurrentReplay(token) {
                let end = min(offset + 4096, snapshot.count)
                let chunk = Data(snapshot[offset..<end])
                client.send(.ringBuffer(paneID: paneID, data: chunk.base64EncodedString()))
                offset = end
            }
            guard subscriber.isCurrentReplay(token) else { return }
            client.send(.ringBufferDone(paneID: paneID))
        }
    }

    func removeSubscriber(_ client: ClientSession) {
        lock.lock()
        if let idx = subscribers.firstIndex(where: { $0.client === client }) {
            // Invalidate before dropping from the array — closures already enqueued on this
            // subscriber's queue hold their own strong reference to it regardless of the array
            // removal, so without this they'd still run and write to a closed/reused fd.
            subscribers[idx].invalidate()
            subscribers.remove(at: idx)
        }
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

        // Through the same per-subscriber queue as replay/live — otherwise .dead could reach a
        // client ahead of a still-in-flight replay or live send for the same pane.
        for subscriber in subs {
            subscriber.queue.async { [paneID] in
                guard subscriber.isValid else { return }
                subscriber.client.send(.dead(paneID: paneID, exitCode: code))
            }
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
