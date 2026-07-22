import Foundation

final class RingBuffer {
    // ponytail: fixed floor/ceiling; revisit if a real workload needs replay depth outside this range.
    static let minCapacity = 4 * 1024
    static let maxCapacity = 16 * 1024 * 1024

    private var buf: [UInt8]
    private var writeHead = 0
    private var count = 0
    private(set) var capacity: Int

    // Clamped so a zero/negative/absurdly large requested capacity (e.g. a malformed
    // replayBufferBytes from a create request) can't divide-by-zero in append()/readAll(),
    // crash on a negative Array count, or exhaust memory — instead of trusting the caller.
    init(capacity: Int = 256 * 1024) {
        self.capacity = min(max(capacity, Self.minCapacity), Self.maxCapacity)
        buf = [UInt8](repeating: 0, count: self.capacity)
    }

    // A PTY already running when a caller asks for a bigger buffer (e.g. an Agents-tab attach
    // against a session that pre-dates this feature) can't be recreated without losing the process —
    // so growth happens in place instead. Never shrinks: a smaller request would silently drop
    // history a caller may still rely on, and no caller currently sends one.
    func growIfNeeded(to requested: Int) {
        let clamped = min(max(requested, Self.minCapacity), Self.maxCapacity)
        guard clamped > capacity else { return }
        let existing = readAll()
        capacity = clamped
        buf = [UInt8](repeating: 0, count: clamped)
        writeHead = 0
        count = 0
        write(existing)
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
