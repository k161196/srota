import Darwin
import Foundation

final class ClientSession {
    let fd: Int32
    private let registry: PTYRegistry
    private var readBuffer = Data()
    private var readSource: DispatchSourceRead?
    // Multiple PTYProcess instances (each on its own concurrent read-source thread) can call
    // send() on the same client at once — e.g. ring-buffer replay from attach() racing live
    // output from another pane. Without this, interleaved write() calls corrupt the newline-
    // delimited JSON stream the client parses.
    private let writeLock = NSLock()

    // Self-retain: DispatchSource holds event handler closure that captures self.
    // Released when source is cancelled on disconnect.
    private var selfRetain: ClientSession?

    init(fd: Int32, registry: PTYRegistry) {
        self.fd = fd
        self.registry = registry
        selfRetain = self
        registry.addClient(self)
        startReadLoop()
    }

    // MARK: - Read loop

    private func startReadLoop() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        src.setEventHandler { [self] in handleReadable() }
        src.setCancelHandler { [self] in
            registry.removeClient(self)
            Darwin.close(fd)
            selfRetain = nil
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
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard let req = try? JSONDecoder().decode(DaemonRequest.self, from: line) else {
            send(.error("bad request", requestID: nil))
            return
        }
        registry.handle(req, client: self)
    }

    // MARK: - Send

    func send(_ response: DaemonResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(UInt8(ascii: "\n"))
        writeLock.lock()
        defer { writeLock.unlock() }
        _ = writeAll(fd: fd, data: data)
    }

    // Forces this connection closed — used when a PTYProcess subscriber gives up on a
    // permanently stuck client (see PTYProcess.overflowGiveUp). cancel() only schedules the
    // cancel handler (registry.removeClient + fd close) to run later on this source's own
    // queue, so this is safe to call inline from another thread without risking reentrancy.
    // The app's own DaemonConnection detects the resulting EOF and reconnects/re-attaches
    // every pane on its own, which is what actually unfreezes the view.
    func disconnect() {
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
