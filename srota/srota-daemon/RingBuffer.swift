import Foundation

// ponytail: fixed 256KB in-memory ring per PTY; add per-session capacity if replay depth matters.
final class RingBuffer {
    private var buf: [UInt8]
    private var writeHead = 0
    private var count = 0
    let capacity: Int

    init(capacity: Int = 256 * 1024) {
        self.capacity = capacity
        buf = [UInt8](repeating: 0, count: capacity)
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { ptr in
            for byte in ptr { append(byte) }
        }
    }

    // Oldest to newest, handles wrap-around
    func readAll() -> Data {
        guard count > 0 else { return Data() }
        var out = [UInt8](repeating: 0, count: count)
        let readHead = count < capacity ? 0 : writeHead
        for i in 0..<count { out[i] = buf[(readHead + i) % capacity] }
        return Data(out)
    }

    private func append(_ byte: UInt8) {
        buf[writeHead] = byte
        writeHead = (writeHead + 1) % capacity
        if count < capacity { count += 1 }
    }
}
