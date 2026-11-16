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
    let state = OSAllocatedUnfairLock<(value: Value?, ended: Bool, released: Bool)>(
        initialState: (nil, false, false))
    Thread {
        let value = call()
        state.withLock {
            if !$0.released { $0.value = value }
            $0.ended = true
        }
    }.start()
    await until(limit: limit, "the call waits for a writer of \(fifo.lastPathComponent)") {
        state.withLock { $0.ended }
    }
    let waits = state.withLock { current -> Bool in
        current.released = !current.ended
        return current.released
    }
    if waits {
        await until(limit: limit, "the call does not end after a writer opens \(fifo.lastPathComponent)") {
            let writer = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            if writer >= 0 { close(writer) }
            return state.withLock { $0.ended }
        }
    }
    return state.withLock { $0.value }
}
