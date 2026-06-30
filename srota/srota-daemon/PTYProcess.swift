import Foundation
import Darwin

// ponytail: forkpty deprecated macOS 14+ but still works — upgrade to posix_openpt if needed
final class PTYProcess {
    let paneID: String
    let stableID: String
    let initialCWD: String
    private(set) var pid: pid_t = -1
    private(set) var exitCode: Int32? = nil

    private var masterFD: Int32 = -1
    private let ring = RingBuffer()
    private var subscribers: [ClientSession] = []
    private let lock = NSLock()
    private var readSource: DispatchSourceRead?

    var info: PTYInfo {
        lock.lock(); defer { lock.unlock() }
        return PTYInfo(paneID: paneID, stableID: stableID, pid: pid, cwd: initialCWD, exitCode: exitCode)
    }

    init(paneID: String, stableID: String, cmd: [String], cwd: String, env: [String: String]) throws {
        self.paneID = paneID
        self.stableID = stableID
        self.initialCWD = cwd
        try spawn(cmd: cmd, cwd: cwd, env: env)
    }

    // MARK: - Spawn

    private func spawn(cmd: [String], cwd: String, env: [String: String]) throws {
        var masterFD: Int32 = -1

        // Merge env: system → caller overrides → daemon-injected
        var mergedEnv = ProcessInfo.processInfo.environment
        for (k, v) in env { mergedEnv[k] = v }
        mergedEnv["SROTA_PANE_ID"] = stableID
        mergedEnv["SROTA_SOCKET_PATH"] = ProcessInfo.processInfo.environment["SROTA_SOCKET_PATH"]
            ?? "\(NSHomeDirectory())/.srota/daemon.sock"
        if mergedEnv["TERM"] == nil { mergedEnv["TERM"] = "xterm-256color" }
        if mergedEnv["TERM_PROGRAM"] == nil { mergedEnv["TERM_PROGRAM"] = "srota" }

        let shell = cmd.isEmpty
            ? [ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"]
            : cmd

        var ws = winsize(); ws.ws_col = 220; ws.ws_row = 50
        let childPID = forkpty(&masterFD, nil, nil, &ws)
        guard childPID >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }

        if childPID == 0 {
            // Child: only POSIX calls between fork and exec
            if !cwd.isEmpty { Darwin.chdir(cwd) }
            for (k, v) in mergedEnv { Darwin.setenv(k, v, 1) }
            var args = shell.map { strdup($0) } + [nil]
            Darwin.execvp(shell[0], &args)
            Darwin._exit(1)
        }

        self.pid = childPID
        self.masterFD = masterFD
        startReadLoop()
    }

    // MARK: - Read loop

    private func startReadLoop() {
        let src = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global())
        src.setEventHandler { [weak self] in self?.handleOutput() }
        src.setCancelHandler { Darwin.close(self.masterFD) }
        src.resume()
        readSource = src
    }

    private func handleOutput() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(masterFD, &buf, buf.count)
        guard n > 0 else { readSource?.cancel(); return }

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

    // Register BEFORE replay so no bytes fall through the gap
    func attach(client: ClientSession) {
        lock.lock()
        subscribers.append(client)
        let snapshot = ring.readAll()
        lock.unlock()

        // Replay in 4KB chunks — avoids huge single JSON lines
        var offset = 0
        while offset < snapshot.count {
            let end = min(offset + 4096, snapshot.count)
            let chunk = Data(snapshot[offset..<end])
            client.send(.ringBuffer(paneID: paneID, data: chunk.base64EncodedString()))
            offset = end
        }
    }

    func removeSubscriber(_ client: ClientSession) {
        lock.lock()
        subscribers.removeAll { $0 === client }
        lock.unlock()
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { ptr in
            _ = Darwin.write(masterFD, ptr.baseAddress!, ptr.count)
        }
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
        for client in subs { client.send(.dead(paneID: paneID, exitCode: code)) }
    }

    func terminate() {
        Darwin.kill(pid, SIGTERM)
        readSource?.cancel()
    }
}
