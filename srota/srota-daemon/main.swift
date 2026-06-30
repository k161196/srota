import Foundation
import Darwin

// Socket path: SROTA_SOCKET_PATH env var, or default ~/.srota/daemon.sock
let srotaDir = ProcessInfo.processInfo.environment["SROTA_DIR"] ?? ".srota"
let socketPath = ProcessInfo.processInfo.environment["SROTA_SOCKET_PATH"]
    ?? "\(NSHomeDirectory())/\(srotaDir)/daemon.sock"

// Ensure ~/.srota/ exists
try? FileManager.default.createDirectory(
    atPath: "\(NSHomeDirectory())/\(srotaDir)",
    withIntermediateDirectories: true
)

let registry = PTYRegistry()

// MARK: - Signal handling

// Ignore SIGPIPE so broken client connections don't crash the daemon
signal(SIGPIPE, SIG_IGN)

// Poll for exited children every second — simpler than SIGCHLD dispatch source
// ponytail: 1s poll, good enough — switch to SIGCHLD source if latency matters
let reapTimer = DispatchSource.makeTimerSource(queue: .global())
reapTimer.schedule(deadline: .now(), repeating: .seconds(1))
reapTimer.setEventHandler {
    var status: Int32 = 0
    while true {
        let pid = waitpid(-1, &status, WNOHANG)
        if pid <= 0 { break }
        if (status & 0x7f) == 0 { registry.reapExited(pid: pid, exitCode: (status >> 8) & 0xff) }
    }
}
reapTimer.resume()

// MARK: - Unix domain socket

// Always remove stale socket — safe because launchd restarts us quickly
Darwin.unlink(socketPath)

let serverFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
guard serverFD >= 0 else { fatalError("[srota-daemon] socket() failed: \(errno)") }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
    socketPath.withCString { src in
        _ = Darwin.strlcpy(
            UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
            src,
            MemoryLayout.size(ofValue: addr.sun_path)
        )
    }
}

let bindResult = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bindResult == 0 else { fatalError("[srota-daemon] bind() failed: \(errno)") }
Darwin.listen(serverFD, 16)

// MARK: - Accept loop

let acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverFD, queue: .global())
acceptSource.setEventHandler {
    let clientFD = Darwin.accept(serverFD, nil, nil)
    guard clientFD >= 0 else { return }
    _ = ClientSession(fd: clientFD, registry: registry)
}
acceptSource.resume()

print("[srota-daemon] listening at \(socketPath)")
dispatchMain()
