import Foundation
import Darwin

final class ClientSession {
    let fd: Int32
    private let registry: PTYRegistry
    private var readBuffer = Data()
    private var readSource: DispatchSourceRead?

    // Self-retain: DispatchSource holds event handler closure which captures self.
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
            selfRetain = nil     // release self-retain → dealloc if no other holders
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
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard let req = try? JSONDecoder().decode(DaemonRequest.self, from: line) else {
            send(.error("bad request"))
            return
        }
        registry.handle(req, from: self)
    }

    // MARK: - Send

    func send(_ response: DaemonResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { ptr in
            _ = Darwin.write(fd, ptr.baseAddress!, ptr.count)
        }
    }
}
