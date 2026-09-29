import Foundation
import Testing

/// Measures how long the tests of this process wait for the concurrency pool and for the main
/// actor (tdd skill, the monitor rule). It runs only when `DIRIGIBLE_FLAKE_MONITOR` names a
/// folder. Every 100 ms, it times a pool hop and a main-actor hop. A watchdog thread outside
/// the pool runs `/usr/bin/sample` when a hop waits longer than the threshold, so the sample
/// shows the code that holds the pool or the main actor.
///
/// - `DIRIGIBLE_FLAKE_MONITOR_SECONDS`: the duration, default 170 s (more than one fast suite).
/// - `DIRIGIBLE_FLAKE_MONITOR_SAMPLE`: the sample threshold in seconds, default 2. When it is
///   set, the first pool hop holds its own task for the threshold plus 1 s, so the watchdog must
///   take a sample. This checks the sample step also when the monitor runs alone.
struct FlakeMonitor {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_FLAKE_MONITOR"] != nil))
    func monitor() async throws {
        let environment = ProcessInfo.processInfo.environment
        let folder = URL(filePath: try #require(environment["DIRIGIBLE_FLAKE_MONITOR"]))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let duration = environment["DIRIGIBLE_FLAKE_MONITOR_SECONDS"].flatMap(Double.init) ?? 170
        let forced = environment["DIRIGIBLE_FLAKE_MONITOR_SAMPLE"].flatMap(Double.init)
        let threshold = forced ?? 2
        let hops = Hops()
        let watchdog = Watchdog(hops: hops, threshold: threshold, folder: folder)
        watchdog.start()

        let start = ProcessInfo.processInfo.systemUptime
        let startDate = Int(Date.now.timeIntervalSince1970)
        var hold = forced.map { $0 + 1 }
        var log = ""
        var worst = (pool: 0.0, main: 0.0)
        while ProcessInfo.processInfo.systemUptime - start < duration {
            let holdNow = hold
            hold = nil
            let pool = await hops.time("pool") {
                await Task.detached { if let holdNow { usleep(UInt32(holdNow * 1_000_000)) } }.value
            }
            let main = await hops.time("main") { await MainActor.run {} }
            for (kind, wait) in [("pool", pool), ("main", main)] where wait.seconds > 0.3 {
                log += String(format: "%@ %.1f %.2f\n", kind, wait.start - start, wait.seconds)
            }
            worst = (max(worst.pool, pool.seconds), max(worst.main, main.seconds))
            try? await Task.sleep(for: .milliseconds(100))
        }
        let samples = await watchdog.stop()
        try Data(log.utf8).write(to: folder.appending(path: "hops.txt"))
        // The start (seconds since 1970) shows how late the monitor started in the suite.
        print(
            String(
                format: "FLAKE-MONITOR worst pool %.2f s, worst main %.2f s, samples %d, start %d", worst.pool,
                worst.main, samples, startDate))
        if forced != nil { #expect(samples > 0, "the monitor took no sample") }
    }
}

/// The hop that runs now: its kind and its start time. The watchdog thread reads it.
private final class Hops: @unchecked Sendable {
    private let lock = NSLock()
    private var current: (id: Int, kind: String, start: Double)?
    private var count = 0

    func time(_ kind: String, _ hop: () async -> Void) async -> (start: Double, seconds: Double) {
        let start = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            count += 1
            current = (count, kind, start)
        }
        await hop()
        lock.withLock { current = nil }
        return (start, ProcessInfo.processInfo.systemUptime - start)
    }

    var now: (id: Int, kind: String, start: Double)? { lock.withLock { current } }
}

/// A thread outside the pool that samples the process when a hop waits longer than the
/// threshold: one sample for each stuck hop, one at a time, at most 10 for each run.
private final class Watchdog: @unchecked Sendable {
    private let hops: Hops
    private let threshold: Double
    private let folder: URL
    private let lock = NSLock()
    private var stopping = false
    private var ended = false
    private var samples = 0

    init(hops: Hops, threshold: Double, folder: URL) {
        self.hops = hops
        self.threshold = threshold
        self.folder = folder
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "FlakeMonitor.watchdog"
        thread.start()
    }

    private func run() {
        let origin = ProcessInfo.processInfo.systemUptime
        var sampled = 0
        while !lock.withLock({ stopping }) {
            if let hop = hops.now, hop.id != sampled, lock.withLock({ samples }) < 10,
                ProcessInfo.processInfo.systemUptime - hop.start > threshold
            {
                sampled = hop.id
                sample("\(hop.kind)-\(Int(max(0, hop.start - origin)))s-\(hop.id).txt")
            }
            usleep(50_000)
        }
        lock.withLock { ended = true }
    }

    private func sample(_ name: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sample")
        process.arguments = ["\(getpid())", "2", "-file", folder.appending(path: name).path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
        if process.terminationStatus == 0 { lock.withLock { samples += 1 } }
    }

    /// Stops the thread and returns the count of samples. A sample takes about 3 s.
    func stop() async -> Int {
        lock.withLock { stopping = true }
        let end = ContinuousClock.now + .seconds(10)
        while !lock.withLock({ ended }) {
            guard ContinuousClock.now < end else {
                Issue.record("The watchdog did not stop in 10 s")
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return lock.withLock { samples }
    }
}
