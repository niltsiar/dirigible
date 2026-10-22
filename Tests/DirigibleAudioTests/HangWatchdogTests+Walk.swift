import CMainStack
import Foundation
import os

/// One walk and its suspend window in `mach_absolute_time` ticks.
typealias WalkWindow = (status: kern_return_t, start: UInt64, end: UInt64)

func walkWindow(_ thread: ms_thread, pause: Bool) -> WalkWindow {
    var frames = [UInt](repeating: 0, count: 128)
    let result = ms_walk(thread, &frames, Int32(frames.count))
    if pause { usleep(1000) }
    return (result.status, result.suspended_at, result.resumed_at)
}

/// True when an ascending list of stamps has one between `start` and `end`.
func holdsStamp<Stamps: RandomAccessCollection<UInt64>>(_ stamps: Stamps, after start: UInt64, before end: UInt64)
    -> Bool where Stamps.Index == Int
{
    var low = 0
    var high = stamps.count
    while low < high {
        let middle = (low + high) / 2
        if stamps[middle] <= start { low = middle + 1 } else { high = middle }
    }
    return low < stamps.count && stamps[low] < end
}

/// Runs `body` on a new thread of `qos` and returns its result, or nil after `limit`.
func onThread<T: Sendable>(
    _ qos: QualityOfService, limit: Duration = .seconds(20), _ body: @escaping @Sendable () -> T
) async -> T? {
    let result = OSAllocatedUnfairLock<T?>(initialState: nil)
    let thread = Thread { result.withLock { $0 = body() } }
    thread.qualityOfService = qos
    thread.start()
    let end = ContinuousClock.now + limit
    while ContinuousClock.now < end {
        if let value = result.withLock({ $0 }) { return value }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return nil
}

/// A user-interactive thread that stores `mach_absolute_time` each 2 us or more in a
/// preallocated array while `stamps(true)` holds, until `stop`. The stamps under `count` do not
/// change. With no stamps, it sleeps, so it adds no load.
final class Bystander: @unchecked Sendable {
    static let capacity = 1 << 21
    private let stamps = UnsafeMutablePointer<UInt64>.allocate(capacity: capacity)
    private let state = OSAllocatedUnfairLock(
        initialState: (thread: ms_thread?.none, stamps: false, stop: false, count: 0, done: false))

    /// Starts the thread and returns it, or nil after 20 s.
    func started() async -> ms_thread? {
        let thread = Thread { self.run() }
        thread.qualityOfService = .userInteractive
        thread.start()
        let end = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < end {
            if let thread = state.withLock({ $0.thread }) { return thread }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func stop() { state.withLock { $0.stop = true } }

    func stamps(_ on: Bool) { state.withLock { $0.stamps = on } }

    /// Stops the thread and returns its stamps, or nil after 20 s.
    func stopped() async -> [UInt64]? {
        stop()
        let end = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < end {
            if let count = state.withLock({ $0.done ? $0.count : nil }) {
                defer { stamps.deallocate() }
                return Array(UnsafeBufferPointer(start: stamps, count: count))
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    private func run() {
        state.withLock { $0.thread = ms_thread_current() }
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        let gap = 2_000 * UInt64(timebase.denom) / UInt64(timebase.numer)
        var count = 0
        var last: UInt64 = 0
        var stamping = false
        while true {
            let now = mach_absolute_time()
            if stamping, now - last >= gap, count < Self.capacity {
                stamps[count] = now
                count += 1
                last = now
            }
            let total = count
            let (stop, on) = state.withLock { state in
                state.count = total
                return (state.stop, state.stamps)
            }
            if stop { break }
            if !on { usleep(100) }
            stamping = on
        }
        state.withLock { $0.done = true }
    }

    /// True when a stamp so far lies inside the window.
    func hasStamp(inside window: WalkWindow) -> Bool {
        let count = state.withLock { $0.count }
        return holdsStamp(UnsafeBufferPointer(start: stamps, count: count), after: window.start, before: window.end)
    }
}
