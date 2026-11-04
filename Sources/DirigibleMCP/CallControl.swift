import DirigibleAudio
import Foundation

/// The controls of one `tools/call` in `dirigible mcp` (decision 0049). `MCPServer` makes one for
/// each call and gives it to the route and to the tool. It is `@unchecked Sendable`: one lock
/// serializes each caller, also the threads of `concurrentPerform`, so the poll reads the
/// one-thread `LineInput` only under the lock.
package final class CallControl: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = ProgressGate()
    private var cancelled = false
    private var polled: ContinuousClock.Instant?
    /// The `_meta.progressToken` of the call, a string or an integer, or nil.
    private let token: Any?
    private let interval: Duration
    private let send: (String) -> Void
    private let poll: (_ read: Bool) -> Bool
    private let step: () -> Void
    /// The journal of a removal fault of `editPackageCore` (decision 0071).
    package let log: () -> DiagnosticLog

    /// `poll` reads stdin when `read` is true, and gives true when a buffered line cancels this
    /// call. `step` runs after each report; tests hold the job with it.
    init(
        token: Any?, interval: Duration, send: @escaping (String) -> Void, poll: @escaping (Bool) -> Bool,
        step: @escaping () -> Void, log: @escaping () -> DiagnosticLog = { .disabled }
    ) {
        (self.token, self.interval, self.send, self.poll, self.step, self.log) = (
            token, interval, send, poll, step, log
        )
    }

    /// Sends `notifications/progress` when the call has a token and the gate passes `fraction`
    /// (0...1).
    package func report(_ fraction: Double) {
        lock.withLock {
            guard let token, !cancelled, let value = gate.pass(fraction, at: .now) else { return }
            let params: [String: Any] = ["progressToken": token, "progress": value, "total": 100]
            send(MCPServer.encode(["jsonrpc": "2.0", "method": "notifications/progress", "params": params]))
        }
        step()
    }

    /// True when a buffered stdin line cancels this call. It reads stdin at most once in
    /// `interval`; the first call always reads. Once true, it stays true.
    package func isCancelled() -> Bool {
        lock.withLock {
            guard !cancelled else { return true }
            let now = ContinuousClock.now
            let read = polled.map { $0.duration(to: now) >= interval } ?? true
            if read { polled = now }
            cancelled = poll(read)
            return cancelled
        }
    }

    /// True when a poll found the cancel: the call then gets no answer (MCP 2026-07-28).
    var cancelSeen: Bool { lock.withLock { cancelled } }
}

/// The one owner of "progress grows and is not too frequent" (decision 0049). A value is the
/// fraction x 100 with one decimal. It passes when it grows by 1 or more, or grows at all 10 s
/// after the last pass. The first value passes. 100 never passes: the answer follows.
struct ProgressGate: Sendable {
    /// The last value that passed, in tenths of a percent, and its time.
    private var last: (tenths: Int, at: ContinuousClock.Instant)?

    mutating func pass(_ fraction: Double, at now: ContinuousClock.Instant) -> Double? {
        let tenths = Int((min(max(fraction, 0), 1) * 1000).rounded())
        guard tenths < 1000 else { return nil }
        if let last {
            guard tenths > last.tenths else { return nil }
            guard tenths - last.tenths >= 10 || last.at.duration(to: now) >= .seconds(10) else { return nil }
        }
        last = (tenths, now)
        return Double(tenths) / 10
    }
}
