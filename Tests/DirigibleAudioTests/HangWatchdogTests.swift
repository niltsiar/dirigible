import CMainStack
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// The hang watchdog of decision 0059 on a test-owned queue and thread, with short limits.
@MainActor struct HangWatchdogTests {
    let folder: TemporaryFolder

    init() throws { folder = try TemporaryFolder() }

    /// C10: the burst writes the images, then 10 raw stacks of the blocked thread, then the names.
    @Test func aLongBlockWritesTheStackOfTheBlockingFunction() async throws {
        let log = startLog(in: folder.url)
        let queue = DispatchQueue(label: "HangWatchdogTests.blocked")
        let gate = Gate(limit: nil)
        let thread = await blockedThread(queue, gate)
        let watchdog = HangWatchdog.start(log: log, ping: queue, thread: thread, limits: .fast, namer: dladdrName)
        defer {
            gate.open()
            watchdog.stop()
        }

        await until(limit: .seconds(20), "10 hang stack lines") {
            hangLines(log, in: folder.url).count { $0.event == "stack" } == 10
        }
        gate.open()
        await until(limit: .seconds(20), "a hang end line and a hang names line") {
            let events = hangLines(log, in: folder.url).map(\.event)
            return events.contains("end") && events.contains("names")
        }

        let lines = hangLines(log, in: folder.url)
        let events = lines.map(\.event).filter { $0 != "names" }
        #expect(events == burstEvents + ["end"], "lines: \(events)")
        #expect(lines.allSatisfy { $0.thread == "Dirigible.Watchdog" }, "threads: \(Set(lines.map(\.thread)))")
        let images = try #require(lines.first { $0.event == "images" })
        #expect(Int(images.fields["count"] ?? "") ?? 0 > 10, "images: \(images.fields["count"] ?? "none")")
        let stack = try #require(lines.first { $0.event == "stack" && $0.frames.count >= 3 }, "no stack of 3 frames")
        #expect(stack.fields["suspend_us"].flatMap(Double.init) != nil)
        let names = try #require(
            lines.first { $0.event == "names" && $0.list("stacks").contains(stack.fields["n"] ?? "") })
        #expect(names.list("names", by: "|").contains { $0.contains("blockInsideTheTestFunction") })
        #expect(!(names.fields["images"] ?? "").contains(NSHomeDirectory()), "images: \(names.fields["images"] ?? "")")
    }

    /// watchdog-hangs C14: the first walk comes before the images line, and the file keeps the
    /// order images, 10 stacks, names. The images step lets the blocked thread go and waits until
    /// it left the blocking function, so a walk after the images step finds an idle thread.
    @Test func theFirstWalkComesBeforeTheImagesLine() async throws {
        let log = startLog(in: folder.url)
        let queue = DispatchQueue(label: "HangWatchdogTests.blocked")
        let gate = Gate(limit: nil)
        let left = Gate(limit: .seconds(20))
        let thread = await blockedThread(queue, gate)
        queue.async { left.open() }
        let watchdog = HangWatchdog.start(
            log: log, ping: queue, thread: thread, limits: .fast, namer: dladdrName,
            images: {
                gate.open()
                left.waitOnce()
                return [("count", .number(0))]
            })
        defer {
            gate.open()
            left.open()
            watchdog.stop()
        }

        await until(limit: .seconds(20), "names lines for the 10 stacks and a hang end line") {
            let lines = hangLines(log, in: folder.url)
            let named = lines.filter { $0.event == "names" }.flatMap { $0.list("stacks") }
            return named.count == 10 && lines.contains { $0.event == "end" }
        }

        let lines = hangLines(log, in: folder.url)
        let burst = lines.map(\.event).filter { $0 != "start" && $0 != "end" }
        let order = ["images"] + [String](repeating: "stack", count: 10)
        #expect(Array(burst.prefix(11)) == order && burst.dropFirst(11).allSatisfy { $0 == "names" }, "lines: \(burst)")
        let first = try #require(lines.first { $0.event == "names" && $0.list("stacks").contains("1") })
        #expect(
            first.list("names", by: "|").contains { $0.contains("blockInsideTheTestFunction") },
            "stack 1: \(first.fields["names"] ?? "")")
    }

    /// C47: a namer that blocks (a main thread in dyld) still finds the raw stacks in the file.
    @Test func theRawStacksComeBeforeTheNames() async throws {
        let log = startLog(in: folder.url)
        let queue = DispatchQueue(label: "HangWatchdogTests.blocked")
        let gate = Gate(limit: nil)
        let namer = Gate(limit: nil)
        let thread = await blockedThread(queue, gate)
        let watchdog = HangWatchdog.start(
            log: log, ping: queue, thread: thread, limits: .fast,
            namer: { address in
                namer.waitOnce()
                return dladdrName(address)
            })
        defer {
            namer.open()
            gate.open()
            watchdog.stop()
        }

        await namer.entered(limit: .seconds(20))

        let held = hangLines(log, in: folder.url).map(\.event)
        #expect(held == burstEvents, "lines: \(held)")
    }

    /// C43: after `stop()` returns, a block of the pinged queue writes no line. The same block
    /// before the stop writes its lines, so the watchdog runs in this test.
    @Test func aStoppedWatchdogWritesNoLine() async throws {
        let log = startLog(in: folder.url)
        let queue = DispatchQueue(label: "HangWatchdogTests.blocked")
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let thread = await blockedThread(queue, gate)
        let limits = HangLimits(
            interval: .milliseconds(50), sleep: .seconds(600), late: .milliseconds(200), bursts: 0)
        let watchdog = HangWatchdog.start(log: log, ping: queue, thread: thread, limits: limits, namer: dladdrName)
        await until(limit: .seconds(20), "a hang start line") {
            hangLines(log, in: folder.url).contains { $0.event == "start" }
        }
        gate.open()
        await until(limit: .seconds(20), "a hang end line") {
            hangLines(log, in: folder.url).contains { $0.event == "end" }
        }

        watchdog.stop()
        let slept = OSAllocatedUnfairLock(initialState: false)
        queue.async {
            Thread.sleep(forTimeInterval: 0.6)
            slept.withLock { $0 = true }
        }
        await until(limit: .seconds(20), "the 600 ms block of the queue") { slept.withLock { $0 } }

        #expect(hangLines(log, in: folder.url).map(\.event) == ["start", "end"])
    }

    /// C11: a bystander thread runs inside the suspend window of a walk of another thread, and
    /// never inside the windows of the walks of itself. Under load the bystander runs in few
    /// windows, so the walks of the other thread go on until a window holds a stamp.
    @Test func theWalkSuspendsOnlyItsThread() async throws {
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let target = await blockedThread(DispatchQueue(label: "HangWatchdogTests.blocked"), gate)
        let bystander = Bystander()
        defer { bystander.stop() }
        let walked = try #require(await bystander.started(), "the bystander did not start")

        let walks = try #require(
            await onThread(.userInteractive) {
                bystander.stamps(true)
                defer { bystander.stamps(false) }
                var other: [WalkWindow] = []
                repeat {
                    other.append(walkWindow(target, pause: false))
                } while other.count < 5000 && !bystander.hasStamp(inside: other[other.count - 1])
                return (other: other, itself: (0..<100).map { _ in walkWindow(walked, pause: true) })
            })
        let stamps = try #require(await bystander.stopped(), "the bystander did not stop")
        try #require(stamps.count < Bystander.capacity, "the stamps filled the buffer before the last walk")

        #expect((walks.other + walks.itself).allSatisfy { $0.status == KERN_SUCCESS && $0.end > $0.start })
        let other = walks.other.count { holdsStamp(stamps, after: $0.start, before: $0.end) }
        let itself = walks.itself.count { holdsStamp(stamps, after: $0.start, before: $0.end) }
        #expect(other >= 1, "windows of the walks of another thread with a bystander stamp: 0 of \(walks.other.count)")
        #expect(itself == 0, "windows of the walks of the bystander with its own stamp: \(itself) of 100")
    }
}

/// C10 with the real main thread: the one suite that pings the main queue and walks main.
@MainActor @Suite(.serialized) struct HangWatchdogMainThreadTests {
    let folder: TemporaryFolder

    init() throws { folder = try TemporaryFolder() }

    @Test func aBlockedMainThreadWritesItsStack() async throws {
        let log = startLog(in: folder.url)
        let limits = HangLimits(
            interval: .milliseconds(20), sleep: .seconds(600), late: .milliseconds(100), burstStacks: 3,
            burstPause: .milliseconds(10))
        let watchdog = HangWatchdog.start(
            log: log, ping: .main, thread: ms_thread_current(), limits: limits, namer: dladdrName)
        defer { watchdog.stop() }

        #expect(blockTheMainThread(until: 3, log, in: folder.url), "no 3 hang stack lines in 5 s")
        await until(limit: .seconds(20), "a hang end line and a hang names line") {
            let events = hangLines(log, in: folder.url).map(\.event)
            return events.contains("end") && events.contains("names")
        }

        let lines = hangLines(log, in: folder.url)
        let stack = try #require(lines.first { $0.event == "stack" && $0.frames.count >= 3 }, "no stack of 3 frames")
        let names = try #require(
            lines.first { $0.event == "names" && $0.list("stacks").contains(stack.fields["n"] ?? "") })
        #expect(names.list("names", by: "|").contains { $0.contains("blockTheMainThread") })
    }
}

extension HangLimits {
    /// A burst of 10 stacks 10 ms apart at the hang start, 100 ms after the ping. No tick of a
    /// loaded test is a sleep.
    static let fast = HangLimits(
        interval: .milliseconds(20), sleep: .seconds(600), late: .milliseconds(100), burstPause: .milliseconds(10))
}

/// The events of a burst of 10 stacks before its names, after the start line.
let burstEvents = ["start", "images"] + [String](repeating: "stack", count: 10)

/// One `hang` line of a journal.
struct HangLine {
    let thread: String
    let event: String
    let fields: [String: String]

    var frames: [String] { list("frames") }

    func list(_ key: String, by separator: Character = ",") -> [String] {
        (fields[key] ?? "").split(separator: separator).map(String.init)
    }
}

/// The `hang` lines of the journals in `folder`, after each queued line is written.
func hangLines(_ log: DiagnosticLog, in folder: URL) -> [HangLine] {
    log.drain()
    return journalFiles(in: folder).flatMap { (try? journalLines(of: $0)) ?? [] }.compactMap { line in
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard columns.count >= 6, columns[4] == "hang" else { return nil }
        return HangLine(thread: columns[2], event: columns[5], fields: fieldValues(columns))
    }
}

/// Runs a block on `queue` that holds its thread inside `blockInsideTheTestFunction` until the
/// gate opens, and returns that thread.
func blockedThread(_ queue: DispatchQueue, _ gate: Gate) async -> ms_thread {
    let thread = OSAllocatedUnfairLock<ms_thread?>(initialState: nil)
    queue.async {
        thread.withLock { $0 = ms_thread_current() }
        blockInsideTheTestFunction(gate)
    }
    await gate.entered(limit: .seconds(20))
    return thread.withLock { $0 } ?? ms_thread()
}

@inline(never) func blockInsideTheTestFunction(_ gate: Gate) {
    gate.waitOnce()
    withExtendedLifetime(gate) {}
}

/// Holds the main thread until the journal has `count` hang stack lines, at most 5 s.
@inline(never) func blockTheMainThread(until count: Int, _ log: DiagnosticLog, in folder: URL) -> Bool {
    let end = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < end {
        if hangLines(log, in: folder).count(where: { $0.event == "stack" }) >= count { return true }
        usleep(5000)
    }
    return false
}

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
