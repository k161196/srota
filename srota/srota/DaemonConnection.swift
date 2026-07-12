import Darwin
import Foundation
import GhosttyTerminal
import Observation

/// Thread-safe box for daemon pane ID, which arrives asynchronously from createPTY.
final class DaemonPaneRef: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var _id: String?
    nonisolated(unsafe) private var _pendingResize: (rows: UInt16, cols: UInt16)?
    nonisolated(unsafe) private var _isReplayingBuffer = false

    nonisolated var id: String? { lock.withLock { _id } }

    /// True while ring buffer is being replayed — suppresses terminal auto-responses from reaching PTY.
    nonisolated var isReplayingBuffer: Bool {
        get { lock.withLock { _isReplayingBuffer } }
        set { lock.withLock { _isReplayingBuffer = newValue } }
    }

    /// Atomically sets the active pane ID and returns any resize buffered before attach.
    nonisolated func setID(_ newID: String) -> (rows: UInt16, cols: UInt16)? {
        lock.withLock {
            _id = newID
            defer { _pendingResize = nil }
            return _pendingResize
        }
    }

    nonisolated func clearID() {
        lock.withLock { _id = nil }
    }

    nonisolated func storePendingResize(rows: UInt16, cols: UInt16) {
        lock.withLock { _pendingResize = (rows, cols) }
    }

    nonisolated func peekPendingResize() -> (rows: UInt16, cols: UInt16)? {
        lock.withLock { _pendingResize }
    }
}

struct PTYInfo {
    let paneID: String
    let stableID: String
    let pid: Int32
    let cwd: String
    let exitCode: Int32?
    let agentStatus: AgentRunStatus?
    let agent: String
    let agentSummary: String
    let agentUpdatedAt: Double?
    let agentSessionID: String?

    nonisolated init?(json: [String: Any]) {
        guard let paneID = json["paneID"] as? String,
              let stableID = json["stableID"] as? String else { return nil }
        self.paneID = paneID
        self.stableID = stableID
        self.pid = (json["pid"] as? Int).map(Int32.init) ?? -1
        self.cwd = json["cwd"] as? String ?? ""
        self.exitCode = (json["exitCode"] as? Int).map(Int32.init)
        self.agentStatus = (json["agentStatus"] as? String).flatMap(AgentRunStatus.init(rawValue:))
        self.agent = json["agent"] as? String ?? ""
        self.agentSummary = json["agentSummary"] as? String ?? ""
        self.agentUpdatedAt = json["agentUpdatedAt"] as? Double
        self.agentSessionID = json["agentSessionID"] as? String
    }
}

// One agent_status broadcast that carries enough to record a session/step (tickets 04/05).
struct AgentHookEvent {
    let stableID: String
    let sessionID: String?
    let provider: String
    let hookEvent: String?
    let summary: String
    let timestamp: Double
}

private final class ManagedSession {
    let stableID: String
    let cwd: String
    let env: [String: String]
    let session: InMemoryTerminalSession
    let ref: DaemonPaneRef
    // A PTY has exactly one live owner at a time (kernel window size, ring-buffer replay, and
    // write-echo suppression all assume a single consumer). Called when a later spawnOrAttach for
    // the same stableID takes over, so the displaced owner can show a "Use Here" reclaim button.
    let onStolen: (() -> Void)?
    var paneID: String?
    var isClosing = false

    init(
        stableID: String,
        cwd: String,
        env: [String: String],
        session: InMemoryTerminalSession,
        ref: DaemonPaneRef,
        onStolen: (() -> Void)?
    ) {
        self.stableID = stableID
        self.cwd = cwd
        self.env = env
        self.session = session
        self.ref = ref
        self.onStolen = onStolen
    }
}

@Observable
final class DaemonConnection {
    private(set) var isConnected = false
    private(set) var agentStatesByStableID: [String: AgentNotificationState] = [:]

    // Fired once a pane is genuinely, permanently closed (not on the ws_panes layout-save churn —
    // see ticket 07 in docs/wayfinder/agent-session-persistence/). Set by whoever owns WorkspaceDB;
    // kept as a closure rather than a direct import so this transport layer stays DB-free.
    var onPaneClosed: ((String) -> Void)?

    // Fired on every agent_status broadcast that carries a sessionID (tickets 04/05) — same
    // DB-free-transport reasoning as onPaneClosed above.
    var onAgentEvent: ((AgentHookEvent) -> Void)?

    @ObservationIgnored private var fd: Int32 = -1
    @ObservationIgnored private var readBuffer = Data()
    @ObservationIgnored private var readSource: DispatchSourceRead?
    @ObservationIgnored private var pendingCreates: [String: CheckedContinuation<String, Error>] = [:]
    @ObservationIgnored private var pendingLists: [String: CheckedContinuation<[PTYInfo], Error>] = [:]
    @ObservationIgnored private var sessionsByPaneID: [String: InMemoryTerminalSession] = [:]
    @ObservationIgnored private var stableIDByPaneID: [String: String] = [:]
    @ObservationIgnored private var managedSessions: [String: ManagedSession] = [:]
    @ObservationIgnored private var restoringStableIDs: Set<String> = []
    @ObservationIgnored private var reconnectScheduled = false
    @ObservationIgnored private let stateLock = NSLock()
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "in.trackk.srota.daemon-io")

    private var socketPath: String {
        "\(NSHomeDirectory())/\(Srota.dir)/daemon.sock"
    }

    // MARK: - Connect

    func connectWithRetry() async {
        if isConnectedSnapshot() { return }
        var delay: UInt64 = 250_000_000
        while !Task.isCancelled {
            do {
                try await connect()
                stateLock.withLock { reconnectScheduled = false }
                await reconcileManagedSessions()
                return
            } catch {}
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 4_000_000_000)
        }
    }

    private func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ioQueue.async { [self] in
                do {
                    try connectSync()
                    cont.resume(returning: ())
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func connectSync() throws {
        if fd >= 0 { return }

        let sockFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sockFD >= 0 else { throw err("socket() failed") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                _ = Darwin.strlcpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                    src,
                    pathSize
                )
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sockFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(sockFD)
            throw err("connect() failed")
        }

        fd = sockFD
        startReadLoop()
        DispatchQueue.main.async { self.isConnected = true }
    }

    // MARK: - Read loop

    private func startReadLoop() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        src.setEventHandler { [weak self] in self?.handleReadable() }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            self.handleDisconnect()
        }
        src.resume()
        readSource = src
    }

    private func handleReadable() {
        var tmp = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &tmp, tmp.count)
        guard n > 0 else {
            readSource?.cancel()
            return
        }
        readBuffer.append(contentsOf: tmp[..<n])
        processLines()
    }

    private func processLines() {
        while let idx = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(readBuffer[..<idx])
            readBuffer = Data(readBuffer[readBuffer.index(after: idx)...])
            guard !line.isEmpty else { continue }
            handle(frame: line)
        }
    }

    private func handle(frame: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "created":
            guard let requestID = json["requestID"] as? String,
                  let paneID = json["paneID"] as? String else { return }
            let cont = stateLock.withLock { pendingCreates.removeValue(forKey: requestID) }
            cont?.resume(returning: paneID)

        case "ring_buffer":
            guard let paneID = json["paneID"] as? String,
                  let encoded = json["data"] as? String,
                  let data = Data(base64Encoded: encoded) else { return }
            let (session, ref) = stateLock.withLock {
                (sessionsByPaneID[paneID], stableIDByPaneID[paneID].flatMap { managedSessions[$0] }?.ref)
            }
            ref?.isReplayingBuffer = true
            session?.receive(data)

        case "ring_buffer_done":
            guard let paneID = json["paneID"] as? String else { return }
            let ref = stateLock.withLock {
                stableIDByPaneID[paneID].flatMap { managedSessions[$0] }?.ref
            }
            ref?.isReplayingBuffer = false

        case "live":
            guard let paneID = json["paneID"] as? String,
                  let encoded = json["data"] as? String,
                  let data = Data(base64Encoded: encoded) else { return }
            let session = stateLock.withLock { sessionsByPaneID[paneID] }
            session?.receive(data)

        case "listed":
            guard let requestID = json["requestID"] as? String else { return }
            let panes = (json["panes"] as? [[String: Any]] ?? []).compactMap(PTYInfo.init)
            let cont = stateLock.withLock { pendingLists.removeValue(forKey: requestID) }
            let states = agentStates(from: panes)
            DispatchQueue.main.async {
                self.agentStatesByStableID = states
                cont?.resume(returning: panes)
            }

        case "dead":
            guard let paneID = json["paneID"] as? String else { return }
            let code = (json["exitCode"] as? Int).map(Int32.init) ?? 0
            let session = stateLock.withLock { detachPaneLocked(paneID: paneID) }
            DispatchQueue.main.async {
                session?.finish(exitCode: UInt32(bitPattern: code), runtimeMilliseconds: 0)
            }

        case "agent_status":
            guard let stableID = json["stableID"] as? String else { return }
            let state = agentState(from: json)
            let event = AgentHookEvent(
                stableID: stableID,
                sessionID: json["sessionID"] as? String,
                provider: json["agent"] as? String ?? "",
                hookEvent: json["hookEvent"] as? String,
                summary: json["summary"] as? String ?? "",
                timestamp: json["updatedAt"] as? Double ?? 0
            )
            DispatchQueue.main.async {
                if let state {
                    self.agentStatesByStableID[stableID] = state
                } else {
                    self.agentStatesByStableID.removeValue(forKey: stableID)
                }
                self.onAgentEvent?(event)
            }

        case "error":
            let message = json["message"] as? String ?? "daemon error"
            guard let requestID = json["requestID"] as? String else { return }
            if let cont = stateLock.withLock({ pendingCreates.removeValue(forKey: requestID) }) {
                cont.resume(throwing: err(message))
                return
            }
            if let cont = stateLock.withLock({ pendingLists.removeValue(forKey: requestID) }) {
                cont.resume(throwing: err(message))
            }

        default:
            break
        }
    }

    private func agentStates(from panes: [PTYInfo]) -> [String: AgentNotificationState] {
        Dictionary(uniqueKeysWithValues: panes.compactMap { pane in
            guard let state = agentState(from: pane) else { return nil }
            return (pane.stableID, state)
        })
    }

    private func agentState(from pane: PTYInfo) -> AgentNotificationState? {
        guard let status = pane.agentStatus, let updatedAt = pane.agentUpdatedAt else { return nil }
        var state = AgentNotificationState()
        state.apply(status: status, agent: pane.agent, summary: pane.agentSummary, timestamp: updatedAt)
        return state
    }

    private func agentState(from json: [String: Any]) -> AgentNotificationState? {
        guard let rawStatus = json["status"] as? String,
              let status = AgentRunStatus(rawValue: rawStatus),
              let updatedAt = json["updatedAt"] as? Double else { return nil }
        var state = AgentNotificationState()
        state.apply(
            status: status,
            agent: json["agent"] as? String ?? "",
            summary: json["summary"] as? String ?? "",
            timestamp: updatedAt
        )
        return state
    }

    private func handleDisconnect() {
        let pending = stateLock.withLock { () -> ([CheckedContinuation<String, Error>], [CheckedContinuation<[PTYInfo], Error>]) in
            let creates = Array(pendingCreates.values)
            let lists = Array(pendingLists.values)
            pendingCreates.removeAll()
            pendingLists.removeAll()
            sessionsByPaneID.removeAll()
            stableIDByPaneID.removeAll()
            restoringStableIDs.removeAll()
            for managed in managedSessions.values {
                managed.paneID = nil
                managed.ref.clearID()
            }
            return (creates, lists)
        }

        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
        readSource = nil
        readBuffer.removeAll(keepingCapacity: false)
        DispatchQueue.main.async {
            self.isConnected = false
            self.agentStatesByStableID.removeAll()
        }

        let disconnectError = err("daemon disconnected")
        pending.0.forEach { $0.resume(throwing: disconnectError) }
        pending.1.forEach { $0.resume(throwing: disconnectError) }
        scheduleReconnect()
    }

    // MARK: - Public API

    func createPTY(cmd: [String], cwd: String, stableID: String, env: [String: String], rows: UInt16? = nil, cols: UInt16? = nil) async throws -> String {
        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { cont in
            ioQueue.async { [self] in
                stateLock.withLock { pendingCreates[requestID] = cont }
                do {
                    var msg: [String: Any] = [
                        "type": "create",
                        "requestID": requestID,
                        "cmd": cmd,
                        "cwd": cwd,
                        "stableID": stableID,
                        "env": env,
                    ]
                    if let rows { msg["rows"] = rows }
                    if let cols { msg["cols"] = cols }
                    try send(msg)
                } catch {
                    let pending = stateLock.withLock { pendingCreates.removeValue(forKey: requestID) }
                    pending?.resume(throwing: error)
                }
            }
        }
    }

    func attach(paneID: String, session: InMemoryTerminalSession) {
        ioQueue.async { [self] in
            stateLock.withLock { sessionsByPaneID[paneID] = session }
            try? send(["type": "attach", "paneID": paneID])
        }
    }

    nonisolated func sendInput(paneID: String, data: Data) {
        let encoded = data.base64EncodedString()
        ioQueue.async { [self] in
            try? send(["type": "input", "paneID": paneID, "data": encoded])
        }
    }

    nonisolated func resize(paneID: String, rows: UInt16, cols: UInt16) {
        ioQueue.async { [self] in
            try? send(["type": "resize", "paneID": paneID, "rows": rows, "cols": cols])
        }
    }

    func list() async throws -> [PTYInfo] {
        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { cont in
            ioQueue.async { [self] in
                stateLock.withLock { pendingLists[requestID] = cont }
                do {
                    try send(["type": "list", "requestID": requestID])
                } catch {
                    let pending = stateLock.withLock { pendingLists.removeValue(forKey: requestID) }
                    pending?.resume(throwing: error)
                }
            }
        }
    }

    /// Registers a terminal session and either attaches immediately or restores it after reconnect.
    /// A PTY has exactly one live owner at a time — calling this for a stableID that's already
    /// claimed elsewhere (e.g. a workspace pane, or an Agents-tab viewer) steals it: the previous
    /// owner's `onStolen` fires so it can show a reclaim ("Use Here") affordance instead of silently
    /// going stale.
    func spawnOrAttach(
        stableID: String,
        cwd: String,
        env: [String: String],
        session: InMemoryTerminalSession,
        into ref: DaemonPaneRef,
        onStolen: (() -> Void)? = nil
    ) {
        let stolen = stateLock.withLock { () -> (() -> Void)? in
            // BUG-2 fix: clean up stale paneID mappings before replacing the managed session
            let existing = managedSessions[stableID]
            if let oldPaneID = existing?.paneID {
                sessionsByPaneID.removeValue(forKey: oldPaneID)
                stableIDByPaneID.removeValue(forKey: oldPaneID)
            }
            existing?.ref.clearID()
            managedSessions[stableID] = ManagedSession(
                stableID: stableID, cwd: cwd, env: env, session: session, ref: ref, onStolen: onStolen
            )
            return existing?.onStolen
        }
        if let stolen { DispatchQueue.main.async(execute: stolen) }

        if isConnectedSnapshot() {
            Task { [weak self] in await self?.restoreManagedSession(stableID: stableID) }
        } else {
            scheduleReconnect()
        }
    }

    func killPane(paneID: String, stableID: String? = nil) {
        if let stableID { onPaneClosed?(stableID) }
        ioQueue.async { [self] in
            try? send(["type": "close", "paneID": paneID])
        }
    }

    func closeSession(stableID: String, paneID: String? = nil) {
        onPaneClosed?(stableID)
        let shouldRestore = stateLock.withLock { () -> Bool in
            guard let managed = managedSessions[stableID] else { return false }
            managed.isClosing = true
            managed.ref.clearID()
            if let paneID {
                managed.paneID = paneID
                sessionsByPaneID[paneID] = managed.session
                stableIDByPaneID[paneID] = stableID
            }
            return managed.paneID == nil
        }

        if shouldRestore {
            Task { [weak self] in await self?.restoreManagedSession(stableID: stableID) }
            return
        }

        requestClose(stableID: stableID)
    }

    // MARK: - Private

    private func scheduleReconnect() {
        let shouldStart = stateLock.withLock { () -> Bool in
            if reconnectScheduled || isConnected {
                return false
            }
            reconnectScheduled = true
            return true
        }
        guard shouldStart else { return }
        Task { [weak self] in
            await self?.connectWithRetry()
        }
    }

    private func reconcileManagedSessions() async {
        let stableIDs = stateLock.withLock { Array(managedSessions.keys) }
        for stableID in stableIDs {
            await restoreManagedSession(stableID: stableID)
        }
    }

    private func restoreManagedSession(stableID: String) async {
        guard beginRestore(stableID: stableID) else { return }
        defer { endRestore(stableID: stableID) }

        guard let managed = stateLock.withLock({ managedSessions[stableID] }) else { return }
        guard isConnectedSnapshot() else {
            scheduleReconnect()
            return
        }

        guard let existing = try? await list() else { return }
        if let match = existing.first(where: { $0.stableID == stableID && $0.exitCode == nil }) {
            if managed.isClosing {
                stateLock.withLock {
                    managed.paneID = match.paneID
                    sessionsByPaneID[match.paneID] = managed.session
                    stableIDByPaneID[match.paneID] = stableID
                }
                requestClose(stableID: stableID)
                return
            }

            if let rebound = bind(paneID: match.paneID, stableID: stableID) {
                // Resize before attaching: the PTY may still be sized from whoever last owned it
                // (or from creation). Attaching first would replay the ring buffer at that stale
                // size, rendering garbled until something happens to trigger a resize later.
                applyPendingResize(for: rebound, paneID: match.paneID)
                attach(paneID: match.paneID, session: rebound.session)
            }
            return
        }

        if managed.isClosing {
            stateLock.withLock {
                managedSessions.removeValue(forKey: stableID)
                managed.ref.clearID()
            }
            return
        }

        // BUG-1 fix: split the guard so a PTY created during the async gap doesn't get orphaned
        let initialSize = managed.ref.peekPendingResize()
        guard let paneID = try? await createPTY(cmd: [], cwd: managed.cwd, stableID: stableID, env: managed.env, rows: initialSize?.rows, cols: initialSize?.cols) else { return }
        guard let rebound = bind(paneID: paneID, stableID: stableID) else {
            // Pane was closed while createPTY was in-flight — kill the orphaned daemon process
            killPane(paneID: paneID)
            _ = stateLock.withLock { managedSessions.removeValue(forKey: stableID) }
            return
        }
        applyPendingResize(for: rebound, paneID: paneID)
        attach(paneID: paneID, session: rebound.session)
    }

    private func beginRestore(stableID: String) -> Bool {
        stateLock.withLock {
            if restoringStableIDs.contains(stableID) {
                return false
            }
            restoringStableIDs.insert(stableID)
            return true
        }
    }

    private func endRestore(stableID: String) {
        _ = stateLock.withLock {
            restoringStableIDs.remove(stableID)
        }
    }

    private func requestClose(stableID: String) {
        ioQueue.async { [self] in
            let paneID = stateLock.withLock { managedSessions[stableID]?.paneID }
            guard let paneID else {
                Task { [weak self] in await self?.restoreManagedSession(stableID: stableID) }
                return
            }
            do {
                try send(["type": "close", "paneID": paneID])
            } catch {
                scheduleReconnect()
            }
        }
    }

    private func bind(paneID: String, stableID: String) -> ManagedSession? {
        stateLock.withLock {
            guard let managed = managedSessions[stableID], !managed.isClosing else { return nil }
            if let oldPaneID = managed.paneID {
                sessionsByPaneID.removeValue(forKey: oldPaneID)
                stableIDByPaneID.removeValue(forKey: oldPaneID)
            }
            managed.paneID = paneID
            sessionsByPaneID[paneID] = managed.session
            stableIDByPaneID[paneID] = stableID
            return managed
        }
    }

    private func applyPendingResize(for managed: ManagedSession, paneID: String) {
        if let pending = managed.ref.setID(paneID) {
            resize(paneID: paneID, rows: pending.rows, cols: pending.cols)
        }
    }

    private func detachPaneLocked(paneID: String) -> InMemoryTerminalSession? {
        let session = sessionsByPaneID.removeValue(forKey: paneID)
        if let stableID = stableIDByPaneID.removeValue(forKey: paneID),
           let managed = managedSessions.removeValue(forKey: stableID) {
            managed.paneID = nil
            managed.ref.clearID()
        }
        return session
    }

    private func isConnectedSnapshot() -> Bool {
        stateLock.withLock { fd >= 0 || isConnected }
    }

    private func send(_ dict: [String: Any]) throws {
        guard fd >= 0 else { throw err("daemon not connected") }
        var data = try JSONSerialization.data(withJSONObject: dict)
        data.append(UInt8(ascii: "\n"))
        guard writeAll(fd: fd, data: data) else {
            readSource?.cancel()
            throw err("daemon write failed")
        }
        if dict["type"] as? String == "close" {
            // Close is best-effort until the daemon reports the child exit.
        }
    }

    private func err(_ msg: String) -> NSError {
        NSError(domain: "SrotaDaemon", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
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
