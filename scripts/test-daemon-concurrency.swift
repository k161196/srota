import Darwin
import Foundation

// PTYProcess.spawn reads this global (normally supplied by srota-daemon's main.swift, which isn't
// compiled into this standalone test since its top-level code would conflict with @main below).
let srotaDir = ".srota"

// Real end-to-end regression tests for two daemon races that were previously fixed by hand-added
// locks (ClientSession.send's writeLock, and holding PTYProcess's lock across the whole of
// attach()/handleOutput()). These spawn real PTYs and a real socketpair rather than mocking the
// lock away, so a regression that reintroduces either race should reliably reproduce here.

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func makeSocketPair() -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    let r = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
    precondition(r == 0, "socketpair failed")
    return (fds[0], fds[1])
}

// Shrinks a socket's kernel buffers so an unread peer backs up (and a blocking write() on it
// stalls) almost immediately, instead of needing megabytes of output to fill a default-sized buffer.
func shrinkSocketBuffers(_ fd: Int32, size: Int32 = 1024) {
    var s = size
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &s, socklen_t(MemoryLayout<Int32>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &s, socklen_t(MemoryLayout<Int32>.size))
}

// Reads newline-delimited JSON DaemonResponse lines off a raw fd (the "app" side of the
// socketpair) and records each message's "type" field, in arrival order.
final class TypeRecorder {
    private var buf = Data()
    private let lock = NSLock()
    private var types: [String] = []

    init(fd: Int32) {
        let thread = Thread {
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = Darwin.read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                self.record(chunk, count: n)
            }
        }
        thread.start()
    }

    private func record(_ chunk: [UInt8], count: Int) {
        lock.lock()
        defer { lock.unlock() }
        buf.append(contentsOf: chunk[..<count])
        while let idx = buf.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buf[..<idx]
            buf.removeSubrange(buf.startIndex...idx)
            if line.isEmpty { continue }
            if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
               let type = obj["type"] as? String {
                types.append(type)
            } else {
                types.append("MALFORMED")
            }
        }
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return types
    }
}

@main
struct DaemonConcurrencyTests {
    static func main() {
        // Mirrors main.swift: a write to a stalled/full socket (this file's slow-client test
        // deliberately creates one) must not crash the process with the default SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        testStaleReleaseDoesNotExpandBudget()
        testConcurrentSendsDontCorruptStream()
        testReplayNeverInterleavesWithLive()
        testSlowClientDoesNotBlockOthers()
        testDisconnectInvalidatesPendingSends()
        testReattachDoesNotDuplicateBytes()
        testOverflowResyncSucceedsWithinRetryBudget()
        testOverflowGivesUpInsteadOfRetryingForever()
        testRepeatedAttachDoesNotStackReplays()
        testSupersededReplayStopsMidFlight()
        print("PASS")
    }

    static func testStaleReleaseDoesNotExpandBudget() {
        let registry = PTYRegistry()
        let (clientFD, peerFD) = makeSocketPair()
        defer { Darwin.close(peerFD) }
        let subscriber = Subscriber(client: ClientSession(fd: clientFD, registry: registry))

        guard case .reserved(let staleGeneration) = subscriber.tryReserve(Subscriber.maxPendingBytes) else {
            expect(false, "failed to fill subscriber budget")
            return
        }
        subscriber.resetBudget()
        guard case .reserved = subscriber.tryReserve(Subscriber.maxPendingBytes) else {
            expect(false, "failed to refill subscriber budget after reset")
            return
        }
        // Release from the generation that existed before resetBudget() arrives only now — after
        // the budget has already been refilled by a new generation's reservation. This is the
        // order that actually happens in production (a stalled subscriber's queue drains its
        // pre-reset closures well after the reset), not release-then-refill.
        subscriber.release(Subscriber.maxPendingBytes, generation: staleGeneration)
        guard case .overflowRetry = subscriber.tryReserve(1) else {
            expect(false, "stale release expanded subscriber budget past its 256KB cap")
            return
        }
    }

    // ClientSession.send() writes to a shared fd; PTYProcess.handleOutput() calls it from each
    // pane's own DispatchSource.global() thread. Two PTYs pushing output at once into the same
    // client used to be able to interleave partial writes and corrupt the newline-delimited JSON
    // stream — this stresses exactly that path.
    static func testConcurrentSendsDontCorruptStream() {
        let registry = PTYRegistry()
        let (clientFD, readerFD) = makeSocketPair()
        let client = ClientSession(fd: clientFD, registry: registry)
        let recorder = TypeRecorder(fd: readerFD)

        let procA = try! PTYProcess(paneID: "pane-a", stableID: "stable-a", cmd: ["/bin/sh", "-c", "yes AAAAAAAAAAAAAAAA"], cwd: "/tmp", env: [:])
        let procB = try! PTYProcess(paneID: "pane-b", stableID: "stable-b", cmd: ["/bin/sh", "-c", "yes BBBBBBBBBBBBBBBB"], cwd: "/tmp", env: [:])
        procA.attach(client: client)
        procB.attach(client: client)

        Thread.sleep(forTimeInterval: 1.0)
        _ = procA.terminate()
        _ = procB.terminate()
        Thread.sleep(forTimeInterval: 0.3)

        let types = recorder.snapshot()
        expect(!types.isEmpty, "expected to observe messages from two concurrently-producing PTYs")
        expect(!types.contains("MALFORMED"), "two PTYs sending concurrently corrupted the JSON stream (unsynchronized socket writes interleaved)")

        Darwin.close(readerFD)
    }

    // attach() replays the ring buffer (subscribing first so no bytes fall through the gap) while
    // handleOutput() keeps delivering live output from the same PTY's real process. Without holding
    // one lock across each side's entire send sequence, a live message could land in the middle of,
    // or ahead of, the replay for that same attach.
    static func testReplayNeverInterleavesWithLive() {
        let registry = PTYRegistry()
        let (clientFD, readerFD) = makeSocketPair()
        let client = ClientSession(fd: clientFD, registry: registry)
        let recorder = TypeRecorder(fd: readerFD)

        let proc = try! PTYProcess(paneID: "pane-c", stableID: "stable-c", cmd: ["/bin/sh", "-c", "yes replay-test-line"], cwd: "/tmp", env: [:])
        // Let real output accumulate in the ring buffer before anyone attaches, then attach while
        // output keeps flowing — the exact window the fix has to serialize.
        Thread.sleep(forTimeInterval: 0.2)
        proc.attach(client: client)
        Thread.sleep(forTimeInterval: 0.5)
        _ = proc.terminate()
        Thread.sleep(forTimeInterval: 0.3)

        let types = recorder.snapshot()
        expect(!types.contains("MALFORMED"), "replay + live output corrupted the JSON stream")
        guard let doneIdx = types.firstIndex(of: "ring_buffer_done") else {
            expect(false, "expected a ring_buffer_done marker after attach")
            return
        }
        expect(!types[..<doneIdx].contains("live"), "a live message overtook replay before ring_buffer_done — attach()/handleOutput() aren't mutually exclusive")

        Darwin.close(readerFD)
    }

    // Ordering was previously enforced by holding PTYProcess's shared `lock` across the actual
    // (blocking) client.send() calls in attach()/handleOutput() — which meant a slow/stalled
    // client could hold that lock indefinitely, blocking every other subscriber's attach, every
    // live send, and any other lock-guarded PTYProcess operation for that pane. This attaches one
    // client whose peer end is never drained (so its writes stall on a full, deliberately shrunk
    // socket buffer) alongside a second, actively-drained client on the SAME PTYProcess, and
    // checks that the second client — and other lock-guarded operations — are never held up by it.
    static func testSlowClientDoesNotBlockOthers() {
        let registry = PTYRegistry()

        let (slowClientFD, slowPeerFD) = makeSocketPair()
        shrinkSocketBuffers(slowClientFD)
        shrinkSocketBuffers(slowPeerFD)
        let slowClient = ClientSession(fd: slowClientFD, registry: registry)
        // slowPeerFD is deliberately never read — the "stalled reader" this test is about.

        let proc = try! PTYProcess(paneID: "pane-slow", stableID: "stable-slow", cmd: ["/bin/sh", "-c", "yes slow-client-blocking-test-line"], cwd: "/tmp", env: [:])
        proc.attach(client: slowClient)

        // Give real PTY output time to fill the shrunk buffer and actually wedge the slow
        // client's queue in a blocking write() call.
        Thread.sleep(forTimeInterval: 0.5)

        let (fastClientFD, fastReaderFD) = makeSocketPair()
        let fastClient = ClientSession(fd: fastClientFD, registry: registry)
        let fastRecorder = TypeRecorder(fd: fastReaderFD)

        let attachStart = Date()
        proc.attach(client: fastClient)
        let attachElapsed = Date().timeIntervalSince(attachStart)
        expect(attachElapsed < 1.0, "attach() for a second client must not block behind a stuck sibling subscriber's queue (took \(attachElapsed)s)")

        let infoStart = Date()
        _ = proc.info
        expect(Date().timeIntervalSince(infoStart) < 1.0, "reading .info must not block behind a stuck subscriber's queue")

        let removeStart = Date()
        proc.removeSubscriber(slowClient)
        expect(Date().timeIntervalSince(removeStart) < 1.0, "removeSubscriber() must not block behind the very subscriber being removed")

        // The fast client should still be getting real replay + live traffic promptly, unaffected
        // by the slow client's stalled queue this whole time.
        Thread.sleep(forTimeInterval: 0.5)
        let fastTypes = fastRecorder.snapshot()
        expect(fastTypes.contains("ring_buffer_done"), "a second client should complete its replay promptly despite a stuck sibling subscriber")
        expect(fastTypes.contains("live"), "a second client should keep receiving live output promptly despite a stuck sibling subscriber")

        _ = proc.terminate()
        Darwin.close(fastReaderFD)
    }

    // removeSubscriber previously only dropped the subscriber from PTYProcess's array — closures
    // already enqueued on its serial queue hold their own strong reference to it (and its client),
    // regardless of the array removal, and would still fire and write to the socket afterward.
    // This proves disconnect actually stops them: after removeSubscriber, no further live output
    // should reach the client's socket even though the PTY keeps producing plenty more of it.
    static func testDisconnectInvalidatesPendingSends() {
        let registry = PTYRegistry()

        let (slowClientFD, slowPeerFD) = makeSocketPair()
        shrinkSocketBuffers(slowClientFD)
        shrinkSocketBuffers(slowPeerFD)
        let slowClient = ClientSession(fd: slowClientFD, registry: registry)
        // slowPeerFD is left undrained at first, so real PTY output backs up the client's queue
        // (and stalls its in-flight write()) exactly like a stuck reader would.

        let proc = try! PTYProcess(paneID: "pane-disconnect", stableID: "stable-disconnect", cmd: ["/bin/sh", "-c", "yes disconnect-invalidation-test-line"], cwd: "/tmp", env: [:])
        proc.attach(client: slowClient)
        Thread.sleep(forTimeInterval: 0.5)

        proc.removeSubscriber(slowClient)

        // Non-blocking from here, over a fixed 1s window — draining is just to observe what
        // arrives, not to participate in any more backpressure. The one message that was already
        // mid-write (blocked in a syscall) at the moment of invalidation is bigger than the shrunk
        // 1KB buffer, so unblocking it can trickle out a few KB across several partial writes as
        // this loop keeps freeing buffer space — that's expected, not a bug.
        _ = fcntl(slowPeerFD, F_SETFL, O_NONBLOCK)
        var totalAfterDisconnect = 0
        var buf = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            let n = Darwin.read(slowPeerFD, &buf, buf.count)
            if n > 0 {
                totalAfterDisconnect += n
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        // A few already-in-flight sends finishing is expected: the 0.5s undrained stall can itself
        // trigger a handful of overflow → auto-resync cycles (each allowed one uninterruptible
        // replay, up to 256KB, that was already mid-write when its subscriber got invalidated) —
        // that's a different fix's behavior, not what this test targets. What this test targets is
        // whether removeSubscriber's OWN invalidation works: if it didn't, the backlog would keep
        // draining and refilling for as long as the PTY keeps producing, growing far beyond a
        // handful of bounded, already-in-flight replays.
        expect(
            totalAfterDisconnect < 512 * 1024,
            "far more than a few trailing messages arrived after removeSubscriber (\(totalAfterDisconnect) bytes) — pending sends weren't invalidated, just removed from the list"
        )

        _ = proc.terminate()
        Darwin.close(slowPeerFD)
    }

    // handleOutput used to release `lock` between ring.write and enqueueing the live send.
    // attach() (already fully atomic on its own side) could acquire `lock` in that gap, snapshot
    // the ring — now including the bytes handleOutput just wrote — and enqueue its replay before
    // handleOutput's own live enqueue for those same bytes ran, delivering them twice. Reattaching
    // the SAME already-subscribed client repeatedly while output streams continuously gives this
    // race many chances to land; monotonically unique output (incrementing line numbers) makes a
    // real duplicate unambiguous — unlike repeated attach() calls alone, which legitimately
    // re-replay the same ring content and would be a false positive if compared naively.
    static func testReattachDoesNotDuplicateBytes() {
        let registry = PTYRegistry()
        let (clientFD, readerFD) = makeSocketPair()
        let client = ClientSession(fd: clientFD, registry: registry)

        // Must be drained continuously, not just at the end — 300 reattaches each replaying up to
        // 256KB would otherwise back up the socket buffer with nobody reading it, which is just
        // the "slow client" scenario from a separate fix, self-inflicted by this test.
        final class RawRecorder {
            private var data = Data()
            private let lock = NSLock()
            init(fd: Int32) {
                let t = Thread {
                    var chunk = [UInt8](repeating: 0, count: 1 << 20)
                    while true {
                        let n = Darwin.read(fd, &chunk, chunk.count)
                        if n <= 0 { break }
                        self.lock.lock()
                        self.data.append(contentsOf: chunk[..<n])
                        self.lock.unlock()
                    }
                }
                t.start()
            }
            func snapshot() -> Data {
                lock.lock()
                defer { lock.unlock() }
                return data
            }
        }
        let recorder = RawRecorder(fd: readerFD)

        let proc = try! PTYProcess(
            paneID: "pane-reattach", stableID: "stable-reattach",
            cmd: ["/bin/sh", "-c", "i=0; while :; do i=$((i+1)); echo LINE-$i; done"],
            cwd: "/tmp", env: [:]
        )
        proc.attach(client: client)

        // Several concurrent hammering threads (not just one) reattaching the same client, to
        // maximize the chance one of them lands on a different core at the exact moment
        // handleOutput is between its ring.write and its enqueue.
        let hammerGroup = DispatchGroup()
        for _ in 0..<4 {
            hammerGroup.enter()
            DispatchQueue.global().async {
                for _ in 0..<300 {
                    proc.attach(client: client)
                }
                hammerGroup.leave()
            }
        }
        hammerGroup.wait()

        Thread.sleep(forTimeInterval: 0.1)
        _ = proc.terminate()
        Thread.sleep(forTimeInterval: 0.1)
        Darwin.close(readerFD)

        let raw = recorder.snapshot()

        // Walk every ring_buffer/live message in arrival order, decoding payloads and carrying
        // partial lines across message boundaries (4096-byte chunk/read boundaries don't align
        // with line boundaries). A line seen via ring_buffer marks it "already replayed"; if that
        // SAME line then shows up in a later live message, that's the bug (replay-then-live is
        // the specific violation — replay-then-replay, or live-then-replay, are both benign).
        var carry = Data()
        var seenViaReplay = Set<String>()
        var duplicate: String?

        outer: for lineData in raw.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                  let type = obj["type"] as? String, type == "ring_buffer" || type == "live",
                  let encoded = obj["data"] as? String,
                  let payload = Data(base64Encoded: encoded) else { continue }

            carry.append(payload)
            while let nl = carry.firstIndex(of: UInt8(ascii: "\n")) {
                let lineBytes = carry[..<nl]
                carry.removeSubrange(carry.startIndex...nl)
                guard let text = String(data: Data(lineBytes), encoding: .utf8), text.hasPrefix("LINE-") else { continue }
                if type == "live" {
                    if seenViaReplay.contains(text) { duplicate = text; break outer }
                } else {
                    seenViaReplay.insert(text)
                }
            }
        }

        expect(duplicate == nil, "\(duplicate ?? "") was delivered via replay and then again via a live message — a reattach raced handleOutput's ring.write/enqueue gap")
    }

    // A subscriber too far behind (over tryReserve's 256KB cap) must not just go silently dark
    // forever — the app still believes it's attached and has no reason of its own to ever request
    // a fresh replay, so a bare detach would leave the pane permanently frozen. This confirms
    // overflow triggers an automatic resync: a fresh, complete ring_buffer/ring_buffer_done replay
    // sequence once the client is able to receive it, not silence and not a resumed raw stream
    // with a gap in it. Uses a BOUNDED burst (~300KB, comfortably under maxConsecutiveOverflows'
    // worth) rather than continuous output — a client left undrained for the ENTIRE overflow
    // window is exactly the "genuinely stuck, give up" case a separate test covers, not this one:
    // this one models recovering (starting to drain) before the retry budget is exhausted.
    static func testOverflowResyncSucceedsWithinRetryBudget() {
        let registry = PTYRegistry()
        let (slowClientFD, slowPeerFD) = makeSocketPair()
        shrinkSocketBuffers(slowClientFD)
        shrinkSocketBuffers(slowPeerFD)
        let slowClient = ClientSession(fd: slowClientFD, registry: registry)

        let proc = try! PTYProcess(
            paneID: "pane-overflow", stableID: "stable-overflow",
            cmd: ["/bin/sh", "-c", "yes overflow-resync-test-line | head -c 300000; sleep 5"],
            cwd: "/tmp", env: [:]
        )
        proc.attach(client: slowClient)

        // Real output, entirely undrained, for long enough for the whole (bounded) burst to land
        // and trigger one overflow → auto-resync cycle internally (well within the retry budget —
        // ~300KB encoded is only ~1.5x the 256KB cap) — then the shell goes quiet.
        Thread.sleep(forTimeInterval: 1.0)

        // Discard whatever's already sitting in the kernel's (shrunk, ~1KB) receive buffer — the
        // initial attach's own replay is tiny (the ring was near-empty when it ran) and fits
        // entirely in that buffer, so it would otherwise still be waiting there, unread, and get
        // mistaken for evidence of a NEW resync the moment anything starts reading.
        _ = fcntl(slowPeerFD, F_SETFL, O_NONBLOCK)
        var discard = [UInt8](repeating: 0, count: 1 << 20)
        let discardDeadline = Date().addingTimeInterval(0.2)
        while Date() < discardDeadline {
            if Darwin.read(slowPeerFD, &discard, discard.count) <= 0 {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        _ = fcntl(slowPeerFD, F_SETFL, 0)

        // Only output arriving from here on counts as "did overflow trigger a NEW resync."
        let recorder = TypeRecorder(fd: slowPeerFD)
        Thread.sleep(forTimeInterval: 1.0)

        _ = proc.terminate()
        Thread.sleep(forTimeInterval: 0.2)

        let types = recorder.snapshot()
        expect(
            types.contains("ring_buffer_done"),
            "no ring_buffer_done arrived after overflow — the client got no automatic resync, so a permanently frozen pane has no way to recover"
        )

        Darwin.close(slowPeerFD)
    }

    // A client whose socket write is genuinely, permanently stuck (ClientSession.writeLock held
    // forever by one syscall that will never return — not merely occasionally slow) must not be
    // retried forever: every retry, even reusing one subscriber and capping it to one pending
    // replay, still adds another batch of captured Data/closures that can never run (hence never
    // free) as long as that lock stays held. Measures the PROCESS'S OWN resident memory directly
    // (byte-counting what eventually drains out doesn't work here — ClientSession.writeLock
    // serializes all sends to one client, so drained throughput is capped regardless of how much
    // backlog exists behind it; RSS is what actually shows unbounded retry cycling). Confirmed
    // this reproduces cleanly against the previous (unbounded) version: ~20MB/s linear growth over
    // 6s undrained, vs. flat within ~1s once bounded.
    static func testOverflowGivesUpInsteadOfRetryingForever() {
        let registry = PTYRegistry()
        let (slowClientFD, slowPeerFD) = makeSocketPair()
        shrinkSocketBuffers(slowClientFD)
        shrinkSocketBuffers(slowPeerFD)
        let slowClient = ClientSession(fd: slowClientFD, registry: registry)

        func currentRSSBytes() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? info.resident_size : 0
        }

        let proc = try! PTYProcess(paneID: "pane-giveup", stableID: "stable-giveup", cmd: ["/bin/sh", "-c", "yes overflow-giveup-test-line"], cwd: "/tmp", env: [:])
        proc.attach(client: slowClient)

        // Long and entirely undrained — many times longer than it takes to exceed
        // maxConsecutiveOverflows against continuous yes-speed output (reached within ~1s).
        // Sampling RSS partway through and again at the end distinguishes "grew once, then
        // stopped" (bounded — the fix) from "keeps growing the whole time" (unbounded — the bug).
        Thread.sleep(forTimeInterval: 2.0)
        let midRSS = currentRSSBytes()
        Thread.sleep(forTimeInterval: 4.0)
        let endRSS = currentRSSBytes()

        let lateGrowth = endRSS >= midRSS ? endRSS - midRSS : 0
        expect(
            lateGrowth < 20 * 1024 * 1024,
            "resident memory grew by \(lateGrowth / 1024)KB between 2s and 6s of continuous undrained output (expected ~flat once the retry budget is exhausted) — overflow is retrying indefinitely instead of giving up on a permanently stuck client"
        )

        _ = proc.terminate()
        Darwin.close(slowPeerFD)
    }

    // Repeated attach() calls against the SAME stalled subscriber used to each enqueue their own
    // up-to-256KB replay snapshot, none of them counted against tryReserve's cap — so the backlog
    // (and memory) could grow without bound purely from reattaching, with no live output at all.
    // This confirms only the newest replay survives: many reattaches produce roughly one replay's
    // worth of total data, not N times that.
    static func testRepeatedAttachDoesNotStackReplays() {
        let registry = PTYRegistry()
        let (slowClientFD, slowPeerFD) = makeSocketPair()
        shrinkSocketBuffers(slowClientFD)
        shrinkSocketBuffers(slowPeerFD)
        let slowClient = ClientSession(fd: slowClientFD, registry: registry)

        // A modest, fixed amount of ring content, then the shell goes quiet — so the numbers below
        // reflect only the replay, not live output arriving during the burst.
        let proc = try! PTYProcess(
            paneID: "pane-replay-stack", stableID: "stable-replay-stack",
            cmd: ["/bin/sh", "-c", "for i in $(seq 1 50); do echo REPLAY-STACK-LINE-$i; done; sleep 5"],
            cwd: "/tmp", env: [:]
        )
        Thread.sleep(forTimeInterval: 0.3)

        // Reattach the same client many times in a tight burst, before the (undrained, stalled)
        // queue could possibly send even the first replay — if replays stacked, this alone would
        // queue dozens of full snapshots.
        for _ in 0..<50 {
            proc.attach(client: slowClient)
        }

        Thread.sleep(forTimeInterval: 0.3)
        _ = fcntl(slowPeerFD, F_SETFL, O_NONBLOCK)
        var total = 0
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            let n = Darwin.read(slowPeerFD, &buf, buf.count)
            if n > 0 { total += n } else { Thread.sleep(forTimeInterval: 0.01) }
        }

        // One replay of ~50 short lines is at most a few KB; 50 stacked replays would be far more.
        expect(
            total < 16 * 1024,
            "far more data arrived than one replay's worth (\(total) bytes) after 50 reattaches — pending replays were stacking instead of being replaced"
        )

        _ = proc.terminate()
        Darwin.close(slowPeerFD)
    }

    // testRepeatedAttachDoesNotStackReplays alone doesn't exercise the real gap:
    // DispatchWorkItem.cancel() only stops a work item that hasn't started running yet (verified
    // separately — cancelling several queued-but-not-yet-dequeued items does successfully skip
    // them). It does nothing once a work item is ALREADY mid-execution, and nothing inside the
    // replay closure checked for that — so a replay that had already started sending chunks when a
    // newer attach() superseded it would just keep running to completion regardless. This uses a
    // large ring (~200KB, ~49 replay chunks) drained at a deliberately throttled rate to reliably
    // catch the first replay partway through, then supersedes it mid-flight and checks it actually
    // stopped instead of finishing alongside the new one.
    static func testSupersededReplayStopsMidFlight() {
        let registry = PTYRegistry()
        let (clientFD, peerFD) = makeSocketPair()
        let client = ClientSession(fd: clientFD, registry: registry)

        let proc = try! PTYProcess(
            paneID: "pane-midflight", stableID: "stable-midflight",
            cmd: ["/bin/sh", "-c", "yes REPLAY-CHUNK-TEST-LINE-0123456789 | head -c 200000; sleep 5"],
            cwd: "/tmp", env: [:]
        )
        // Let the ~200KB land in the ring before attaching, so the first replay has enough chunks
        // to reliably still be mid-flight when it gets superseded below.
        Thread.sleep(forTimeInterval: 0.5)
        proc.attach(client: client)

        // A deliberately slow, steady reader (512 bytes every 5ms, ~100KB/s) — draining the ~270KB
        // one full replay actually sends (200KB base64-inflated plus JSON overhead) takes a
        // couple of seconds, giving a reliable window to catch it partway through.
        final class ThrottledRecorder {
            private var buf = Data()
            private let lock = NSLock()
            private var types: [String] = []
            init(fd: Int32) {
                let t = Thread {
                    var tiny = [UInt8](repeating: 0, count: 512)
                    while true {
                        let n = Darwin.read(fd, &tiny, tiny.count)
                        if n <= 0 { break }
                        self.record(tiny, count: n)
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                }
                t.start()
            }
            private func record(_ chunk: [UInt8], count: Int) {
                lock.lock()
                defer { lock.unlock() }
                buf.append(contentsOf: chunk[..<count])
                while let idx = buf.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buf[..<idx]
                    buf.removeSubrange(buf.startIndex...idx)
                    if line.isEmpty { continue }
                    if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                       let type = obj["type"] as? String {
                        types.append(type)
                    }
                }
            }
            func snapshot() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return types
            }
        }
        let recorder = ThrottledRecorder(fd: peerFD)

        // The first replay is now actively sending (nowhere near done at ~100KB/s against ~270KB
        // of data) — supersede it while it's still mid-flight.
        Thread.sleep(forTimeInterval: 0.8)
        proc.attach(client: client)

        // Generous window for everything to fully drain either way — if the old replay wrongly
        // kept running, this is enough time for both it and the new one to complete.
        Thread.sleep(forTimeInterval: 6.0)
        _ = proc.terminate()
        Thread.sleep(forTimeInterval: 0.3)
        Darwin.close(peerFD)

        let types = recorder.snapshot()
        let doneCount = types.filter { $0 == "ring_buffer_done" }.count
        let chunkCount = types.filter { $0 == "ring_buffer" }.count
        expect(
            doneCount == 1,
            "expected exactly 1 ring_buffer_done (only the newest replay should ever complete), got \(doneCount) — a replay already mid-flight when superseded kept running to completion instead of stopping at its next chunk check"
        )
        expect(
            chunkCount < 70,
            "got \(chunkCount) ring_buffer chunks — roughly double one replay's ~49 chunks, meaning the superseded (mid-flight) replay finished sending alongside the new one instead of stopping early"
        )
    }
}
