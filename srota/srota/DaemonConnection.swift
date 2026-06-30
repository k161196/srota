import Foundation
import Observation
import GhosttyTerminal
import Darwin

/// Thread-safe box for the daemon pane ID, which arrives asynchronously after createPTY.
final class DaemonPaneRef: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var _id: String?
    nonisolated(unsafe) private var _pendingResize: (rows: UInt16, cols: UInt16)?

    nonisolated var id: String? { lock.withLock { _id } }

    /// Atomically sets the ID and returns any resize that arrived before the ID was known.
    nonisolated func setID(_ newID: String) -> (rows: UInt16, cols: UInt16)? {
        lock.withLock {
            _id = newID
            defer { _pendingResize = nil }
            return _pendingResize
        }
    }

    nonisolated func storePendingResize(rows: UInt16, cols: UInt16) {
        lock.withLock { _pendingResize = (rows, cols) }
    }
}

struct PTYInfo {
    let paneID: String
    let stableID: String
    let pid: Int32
    let cwd: String
    let exitCode: Int32?

    init?(json: [String: Any]) {
        guard let paneID = json["paneID"] as? String,
              let stableID = json["stableID"] as? String else { return nil }
        self.paneID = paneID
        self.stableID = stableID
        self.pid = (json["pid"] as? Int).map(Int32.init) ?? -1
        self.cwd = json["cwd"] as? String ?? ""
        self.exitCode = (json["exitCode"] as? Int).map(Int32.init)
    }
}

@Observable
final class DaemonConnection {
    private(set) var isConnected = false

    @ObservationIgnored private var fd: Int32 = -1
    @ObservationIgnored private var readBuffer = Data()
    @ObservationIgnored private var readSource: DispatchSourceRead?
    @ObservationIgnored private var sessions: [String: InMemoryTerminalSession] = [:]
    @ObservationIgnored private var pendingCreates: [CheckedContinuation<String, Error>] = []
    @ObservationIgnored private var pendingLists: [CheckedContinuation<[PTYInfo], Error>] = []
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "in.trackk.srota.daemon-io")

    private var socketPath: String {
        "\(NSHomeDirectory())/\(Srota.dir)/daemon.sock"
    }

    // MARK: - Connect

    func connectWithRetry() async {
        var delay: UInt64 = 250_000_000  // 250ms, doubles each attempt up to 4s
        while !Task.isCancelled {
            do { try await connect(); return } catch {}
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 4_000_000_000)
        }
    }

    private func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ioQueue.async { [self] in
                do { try connectSync(); cont.resume() }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func connectSync() throws {
        let sockFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sockFD >= 0 else { throw err("socket() failed") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                _ = Darwin.strlcpy(
                    UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                    src, pathSize
                )
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sockFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(sockFD); throw err("connect() failed") }

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
            Darwin.close(fd); fd = -1
            DispatchQueue.main.async { self.isConnected = false }
            Task { [weak self] in await self?.connectWithRetry() }
        }
        src.resume()
        readSource = src
    }

    private func handleReadable() {
        var tmp = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &tmp, tmp.count)
        guard n > 0 else { readSource?.cancel(); return }
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
            guard let paneID = json["paneID"] as? String else { return }
            guard !pendingCreates.isEmpty else { return }
            pendingCreates.removeFirst().resume(returning: paneID)

        case "ring_buffer", "live":
            guard let paneID = json["paneID"] as? String,
                  let encoded = json["data"] as? String,
                  let data = Data(base64Encoded: encoded) else { return }
            let session = sessions[paneID]
            // ghostty_surface_write_buffer must be called on main thread
            DispatchQueue.main.async { session?.receive(data) }

        case "listed":
            let panes = (json["panes"] as? [[String: Any]] ?? []).compactMap { PTYInfo(json: $0) }
            guard !pendingLists.isEmpty else { return }
            pendingLists.removeFirst().resume(returning: panes)

        case "dead":
            guard let paneID = json["paneID"] as? String else { return }
            let code = (json["exitCode"] as? Int).map(Int32.init) ?? 0
            let session = sessions[paneID]
            DispatchQueue.main.async { session?.finish(exitCode: UInt32(bitPattern: code), runtimeMilliseconds: 0) }

        case "error":
            let msg = json["message"] as? String ?? "daemon error"
            if !pendingCreates.isEmpty { pendingCreates.removeFirst().resume(throwing: err(msg)) }

        default: break
        }
    }

    // MARK: - Public API

    func createPTY(cmd: [String], cwd: String, stableID: String, env: [String: String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            ioQueue.async { [self] in
                pendingCreates.append(cont)
                send(["type": "create", "cmd": cmd, "cwd": cwd, "stableID": stableID, "env": env])
            }
        }
    }

    func attach(paneID: String, session: InMemoryTerminalSession) {
        ioQueue.async { [self] in
            sessions[paneID] = session
            send(["type": "attach", "paneID": paneID])
        }
    }

    nonisolated func sendInput(paneID: String, data: Data) {
        let encoded = data.base64EncodedString()
        ioQueue.async { [self] in send(["type": "input", "paneID": paneID, "data": encoded]) }
    }

    nonisolated func resize(paneID: String, rows: UInt16, cols: UInt16) {
        ioQueue.async { [self] in
            send(["type": "resize", "paneID": paneID, "rows": rows, "cols": cols])
        }
    }

    func list() async throws -> [PTYInfo] {
        try await withCheckedThrowingContinuation { cont in
            ioQueue.async { [self] in
                pendingLists.append(cont)
                send(["type": "list"])
            }
        }
    }

    /// Try to attach to an existing PTY with matching stableID; create a new one if not found.
    /// Centralises the reconnect-vs-create decision so every pane creation site is one call.
    func spawnOrAttach(
        stableID: String,
        cwd: String,
        env: [String: String],
        session: InMemoryTerminalSession,
        into ref: DaemonPaneRef
    ) {
        Task {
            if let existing = try? await list(),
               let match = existing.first(where: { $0.stableID == stableID && $0.exitCode == nil }) {
                if let pending = ref.setID(match.paneID) {
                    resize(paneID: match.paneID, rows: pending.rows, cols: pending.cols)
                }
                attach(paneID: match.paneID, session: session)
                return
            }
            guard let paneID = try? await createPTY(
                cmd: [], cwd: cwd, stableID: stableID, env: env
            ) else { return }
            if let pending = ref.setID(paneID) {
                resize(paneID: paneID, rows: pending.rows, cols: pending.cols)
            }
            attach(paneID: paneID, session: session)
        }
    }

    func closePTY(paneID: String) {
        ioQueue.async { [self] in
            sessions.removeValue(forKey: paneID)
            send(["type": "close", "paneID": paneID])
        }
    }

    // MARK: - Private

    private func send(_ dict: [String: Any]) {
        guard fd >= 0, var data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
    }

    private func err(_ msg: String) -> NSError {
        NSError(domain: "SrotaDaemon", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
