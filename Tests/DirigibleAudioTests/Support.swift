import AVFoundation
import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Interleaved sine samples with amplitude 0.5. Channel `c` has the frequency
/// `frequency * (c + 1)`, so a test can tell the channels apart.
func sine(seconds: Double, rate: Double, channels: Int = 1, frequency: Double = 1000) -> [Float] {
    let frames = Int((seconds * rate).rounded())
    var samples = [Float](repeating: 0, count: frames * channels)
    for frame in 0..<frames {
        for channel in 0..<channels {
            let phase = 2 * Double.pi * frequency * Double(channel + 1) * Double(frame) / rate
            samples[frame * channels + channel] = Float(0.5 * sin(phase))
        }
    }
    return samples
}

/// A unique temporary folder, removed at deinit off the calling thread.
/// The deinit of a folder in a `@MainActor` suite runs on the main thread. A synchronous
/// remove there held the main actor for a third of a full run (process sample, 2026-09-25).
final class TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "DirigibleAudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { FolderRemovals.remove(url) }
}

/// SplitMix64: a small seeded generator, so a random test gives the same values on each run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// The frames of an audio file as `AVAudioFile` reads them, interleaved. It reads in blocks: one
/// read of the whole length of an unclosed CAF gives fewer frames (probe 2026-09-24: 95232 of
/// 96000), and reads in blocks give all of them.
func readAudio(_ url: URL) throws -> (rate: Double, bits: Int?, samples: [Float]) {
    let file = try AVAudioFile(forReading: url)
    let channels = Int(file.processingFormat.channelCount)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
    var samples: [Float] = []
    samples.reserveCapacity(Int(file.length) * channels)
    while file.framePosition < file.length {
        try file.read(into: buffer)
        if buffer.frameLength == 0 { break }
        let data = try #require(buffer.floatChannelData)
        let frames = Int(buffer.frameLength)
        if channels == 1 {
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            continue
        }
        for frame in 0..<frames {
            for channel in 0..<channels { samples.append(data[channel][frame]) }
        }
    }
    return (file.fileFormat.sampleRate, file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, samples)
}

/// Writes `digit` over byte 7 of the file at `url`: the version digit of a sidecar or anchor
/// magic (decision 0024 P9).
func setMagicDigit(_ url: URL, _ digit: String) throws {
    let handle = try FileHandle(forWritingTo: url)
    try handle.seek(toOffset: 7)
    try handle.write(contentsOf: Data(digit.utf8))
    try handle.close()
}

/// The host time of the take start in the take packages: 1000 s after boot.
let takeStart: UInt64 = 1_000_000_000_000

/// A package with tracks and a `<recording>` in `session.xml`, and segments made by the real
/// `SegmentWriter`. It is removed at deinit.
final class TakePackage {
    let folder: TemporaryFolder
    let url: URL
    var capture: URL { url.appending(path: "Capture") }

    init(
        sampleRate: Int = 48_000, tracks: [(TrackID, ChannelLayout)] = [("t1", .mono)], take: Int = 1,
        playhead: Frames = 96_000
    ) throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: sampleRate)
        for (id, layout) in tracks { try session.addTrack(id, name: id.rawValue, layout: layout) }
        try session.setRecording(
            Recording(
                take: take, playheadFrame: playhead, takeStartHostTimeNanos: takeStart,
                armedTracks: tracks.map(\.0)))
        try session.write(to: url)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
    }

    func read() throws -> Session { try Session(contentsOf: url) }

    static func header(
        rate: Double = 48_000, channels: Int = 1, latency: Int = 48, firstHost: UInt64 = takeStart + 10_000_000
    ) -> CaptureHeader {
        CaptureHeader(
            deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: rate, availableRates: [rate...rate],
            channelCount: channels, latency: latency, firstSampleTime: 512, firstHostTimeNanos: firstHost)
    }

    /// Checkpoints at frame 0, at each whole second, and at the last frame, on a clock that runs
    /// at `realRate` (default: the header rate).
    static func checkpoints(frames: Int, header: CaptureHeader, realRate: Double? = nil) -> [Checkpoint] {
        let rate = realRate ?? header.nominalRate
        let second = Int(rate.rounded())
        return (Array(stride(from: 0, to: frames, by: second)) + [frames - 1]).map { frame in
            Checkpoint(
                fileFrame: Int64(frame), sampleTime: header.firstSampleTime + Double(frame),
                hostTimeNanos: header.firstHostTimeNanos + UInt64((Double(frame) / rate * 1e9).rounded()))
        }
    }

    /// Writes one segment with the real writer. It closes the writer unless `open` is true; the
    /// caller then keeps the returned writer alive as a crashed process.
    @discardableResult
    func segment(
        take: Int = 1, arm: Int = 1, segment: Int = 1, header: CaptureHeader = TakePackage.header(), samples: [Float],
        checkpoints: [Checkpoint]? = nil, open: Bool = false
    ) throws -> SegmentWriter {
        let frames = samples.count / header.channelCount
        let writer = try SegmentWriter(
            folder: capture, name: SegmentName(take: take, arm: arm, segment: segment), header: header)
        for checkpoint in checkpoints ?? Self.checkpoints(frames: frames, header: header) {
            try writer.checkpoint(checkpoint)
        }
        try samples.withUnsafeBufferPointer { try writer.write($0, frames: frames) }
        if !open { try writer.close() }
        return writer
    }
}

/// Records of `frames` frames from interleaved samples. `buffers[i]` holds the samples of buffer
/// `i` with `layout[i]` channels. The host time runs at `rate` from `hostStart`.
func records(
    _ buffers: [[Float]], layout: [Int], rate: Double, frames: Int = 512, sampleStart: Double = 0,
    hostStart: UInt64 = takeStart
) -> [InputRecord] {
    let total = buffers[0].count / layout[0]
    return stride(from: 0, to: total, by: frames).map { start in
        let count = min(frames, total - start)
        return InputRecord(
            sampleTime: sampleStart + Double(start), hostTimeNanos: hostStart + UInt64(Double(start) / rate * 1e9),
            frameCount: count, nominalRate: rate,
            buffers: zip(buffers, layout).map { buffer, channels in
                Array(buffer[(start * channels)..<((start + count) * channels)])
            })!
    }
}

/// The silence and first-record limit of a test writer that no test reaches: one day. A loaded
/// full suite holds a test for more than 60 s, and a watchdog that fires in a test gives a second
/// attach that the test did not ask for. A watchdog test sets its own limit.
let noWatchdog = Duration.seconds(86_400)

/// Runs `body` off the main actor, so a slow child process or disk write does not hold the
/// main-actor tests that measure time.
@concurrent nonisolated func offMainActor(_ body: @Sendable () throws -> Void) async throws { try body() }

/// With `DIRIGIBLE_FLAKE_MONITOR` set, prints `WAIT <helper> <seconds> s <text>` for a wait over
/// 2 s. `scripts/flake-monitor/loop.sh` takes the worst wait of each helper, and the hang guards
/// take their limits from it.
func reportWait(_ helper: String, since start: ContinuousClock.Instant, _ text: String) {
    guard flakeMonitorIsOn else { return }
    let seconds = (ContinuousClock.now - start) / .seconds(1)
    if seconds > 2 { print(String(format: "WAIT %@ %.1f s %@", helper, seconds, text)) }
}

private let flakeMonitorIsOn = ProcessInfo.processInfo.environment["DIRIGIBLE_FLAKE_MONITOR"] != nil

/// Polls `condition` every 10 ms. After `limit`, it records `message` as a test failure. It
/// checks once more after a sleep past the limit, so a main-actor job that another test held
/// back (a report hop) runs before the last check.
///
/// In a full suite, other `@MainActor` suites hold the main actor for up to 18.8 s (run
/// flakes-2, the monitored suite). The limit counts the time of a `Stopwatch`, so such a hold
/// does not use up the limit. `cap` (default 3 x `limit`) is the longest wait in wall time, so a
/// hang still fails.
@MainActor
func until(
    limit: Duration = .seconds(1), cap: Duration? = nil, _ message: String, _ condition: () -> Bool
) async {
    let watch = Stopwatch()
    defer { reportWait("until", since: watch.start, message) }
    let cap = cap ?? limit * 3
    func over() -> Bool { watch.elapsed >= limit || watch.wall >= cap }
    var expired = false
    while !condition() {
        guard !expired else {
            Issue.record("\(message) (limit \(limit))")
            return
        }
        expired = over()
        try? await Task.sleep(for: .milliseconds(10))
        // A hold during the sleep moves the deadline.
        expired = expired && over()
    }
}

/// Holds the first caller of `wait` until `open`, with a limit. It polls, so it blocks no thread
/// of the concurrency pool. Later callers pass.
final class AsyncGate: @unchecked Sendable {
    /// The limit of `wait`. Each limit is 3 times the worst wait: `wait` 28.7 s, `entered` 17.8 s
    /// (run test-pool-health, loops/s3loadb-5.log). The two copies print the same wait text.
    static let openLimit = Duration.seconds(87)
    private let lock = NSLock()
    private var used = false
    private var inside = false
    private var opened = false

    func wait() async {
        guard
            lock.withLock({ () -> Bool in
                defer { used = true }
                inside = !used
                return !used
            })
        else { return }
        let start = ContinuousClock.now
        defer { reportWait("AsyncGate.wait", since: start, "AsyncGate") }
        let end = start + Self.openLimit
        while !lock.withLock({ opened }) {
            guard ContinuousClock.now < end else {
                Issue.record("The gate was not opened in \(Self.openLimit)")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func open() { lock.withLock { opened = true } }

    /// Returns when the first caller is inside `wait`. After `limit`, it records a failure.
    func entered(limit: Duration = .seconds(54)) async {
        let start = ContinuousClock.now
        defer { reportWait("AsyncGate.entered", since: start, "AsyncGate") }
        let end = start + limit
        while !lock.withLock({ inside }) {
            guard ContinuousClock.now < end else {
                Issue.record("No block entered the gate (limit \(limit))")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Holds the first caller of `waitOnce` until `open`, with a limit; later callers pass.
/// A test holds a write with it and waits with `entered` until the write is inside the gate.
/// The autosave starts on the main actor, and in a full suite the `@MainActor` suites hold it
/// for many seconds (their inits write packages with `F_FULLFSYNC`). Each limit is 3 times the
/// worst wait: `waitOnce` 21.8 s (run test-pool-health, loops/base-1.log), `entered` 23.8 s
/// (loops/s3loadb-5.log).
final class Gate: @unchecked Sendable {
    /// The default limit of `waitOnce`.
    static let openLimit = Duration.seconds(66)
    /// The limit of `waitOnce`. Nil: no limit, for a hold that must last until the test opens
    /// it in a `defer` (waits-and-limits.md). A hold with a limit ends when the test is slow.
    private let limit: Duration?
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var used = false
    private var inside = false

    init(limit: Duration? = openLimit) { self.limit = limit }

    @available(*, noasync, message: "It blocks a thread of the concurrency pool. Use AsyncGate in async code.")
    func waitOnce() {
        guard
            lock.withLock({ () -> Bool in
                defer { used = true }
                return !used
            })
        else { return }
        lock.withLock { inside = true }
        // `noasync` refuses this call in async code, but not in a synchronous hook that a
        // `@concurrent` function calls. The label of the current queue names the pool (probe P1 of
        // run test-pool-health), so such a call is an issue, and it returns at once.
        guard !String(cString: __dispatch_queue_get_label(nil)).hasSuffix(".cooperative") else {
            Issue.record("Gate.waitOnce blocks a thread of the concurrency pool")
            return
        }
        let start = ContinuousClock.now
        defer { reportWait("Gate.waitOnce", since: start, "Gate") }
        guard let limit else { return semaphore.wait() }
        if semaphore.wait(timeout: .now() + limit / .seconds(1)) == .timedOut {
            Issue.record("The gate was not opened in \(limit)")
        }
    }

    func open() { semaphore.signal() }

    /// Returns when the first caller is inside `waitOnce`. After `limit`, it records a failure.
    func entered(limit: Duration = .seconds(72)) async {
        let start = ContinuousClock.now
        defer { reportWait("Gate.entered", since: start, "Gate") }
        let end = start + limit
        while !lock.withLock({ inside }) {
            guard ContinuousClock.now < end else {
                Issue.record("No write entered the gate (limit \(limit))")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Counts the calls of a test step and throws on the calls that `fails` names (1-based).
final class StepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let fails: @Sendable (Int) -> Bool

    init(fails: @escaping @Sendable (Int) -> Bool = { _ in false }) { self.fails = fails }

    var calls: Int { lock.withLock { count } }

    /// Adds one call. True when this call must fail.
    func next() -> Bool {
        fails(
            lock.withLock { () -> Int in
                count += 1
                return count
            })
    }
}

/// Removes folders one at a time on a serial utility queue, so parallel deinits do not add
/// threads that compete for the disk. The process waits for the removals at exit, so no folder
/// stays in the temporary directory.
enum FolderRemovals {
    private static let queue = DispatchQueue(label: "FolderRemovals", qos: .utility)
    private static let group: DispatchGroup = {
        atexit { FolderRemovals.group.wait() }
        return DispatchGroup()
    }()

    static func remove(_ url: URL) {
        queue.async(group: group) { try? FileManager.default.removeItem(at: url) }
    }
}
