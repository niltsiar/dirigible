import Foundation
import Testing
import os

/// Puts a FIFO at `url` in place of the file there.
func makeFIFO(at url: URL) throws {
    unlink(url.path)
    try #require(mkfifo(url.path, 0o644) == 0, "mkfifo \(url.lastPathComponent): errno \(errno)")
}

/// Runs `call` on its own thread while the FIFO at `fifo` has no writer, and gives its value.
/// The value is nil when the call ends only after a writer opens the FIFO: an open or a read waits
/// for a writer, so the call ends at no time. After `limit` the test records that issue, then
/// opens and closes a writer at each poll until the call ends.
@MainActor
func valueWithNoWriter<Value: Sendable>(
    of fifo: URL, limit: Duration = .seconds(10), _ call: @escaping @Sendable () -> Value
) async -> Value? {
    await value(of: call, waitingFor: "writer", of: fifo, limit: limit) {
        let writer = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        if writer >= 0 { close(writer) }
    }.value
}

/// `valueWithNoWriter` for a call that writes: an open for writing waits for a reader. After
/// `limit` the test opens one reader and empties the FIFO at each poll until the call ends.
@MainActor
func valueWithNoReader<Value: Sendable>(
    of fifo: URL, limit: Duration = .seconds(10), _ call: @escaping @Sendable () -> Value
) async -> Value? {
    var reader: Int32 = -1
    let capacity = 65_536
    var bytes = [UInt8](repeating: 0, count: capacity)
    let result = await value(of: call, waitingFor: "reader", of: fifo, limit: limit) {
        if reader < 0 { reader = open(fifo.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }
        while reader >= 0 && read(reader, &bytes, capacity) > 0 {}
    }
    // A write of the call after the close of the last reader raises SIGPIPE, which stops the tests.
    if reader >= 0 && result.ended { close(reader) }
    return result.value
}

/// The value of `call`, nil when `release` ran first, and whether the call ended.
@MainActor
private func value<Value: Sendable>(
    of call: @escaping @Sendable () -> Value, waitingFor peer: String, of fifo: URL, limit: Duration,
    release: () -> Void
) async -> (value: Value?, ended: Bool) {
    let state = OSAllocatedUnfairLock<(value: Value?, ended: Bool, released: Bool)>(
        initialState: (nil, false, false))
    Thread {
        let value = call()
        state.withLock {
            if !$0.released { $0.value = value }
            $0.ended = true
        }
    }.start()
    await until(limit: limit, "the call waits for a \(peer) of \(fifo.lastPathComponent)") {
        state.withLock { $0.ended }
    }
    let waits = state.withLock { current -> Bool in
        current.released = !current.ended
        return current.released
    }
    if waits {
        await until(limit: limit, "the call does not end after a \(peer) opens \(fifo.lastPathComponent)") {
            release()
            return state.withLock { $0.ended }
        }
    }
    return state.withLock { ($0.value, $0.ended) }
}
