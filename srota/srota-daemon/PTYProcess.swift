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

    var info: PTYInfo {
        lock.lock()
        defer { lock.unlock() }
        return PTYInfo(paneID: paneID, stableID: stableID, pid: pid, cwd: initialCWD, exitCode: exitCode)
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

    func terminate() {
        guard pid > 0 else { return }
        _ = Darwin.kill(pid, SIGTERM)
        readSource?.cancel()
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
