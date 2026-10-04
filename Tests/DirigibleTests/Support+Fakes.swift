import CoreAudio
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// A closure `DeviceHAL` with one device `duo` (2 channels, 48 kHz, object 7). It counts the
/// attaches and the clean detaches; "the device is free" is `attaches == cleanDetaches`. The app
/// test target cannot import `TestHAL` of `DirigibleAudioTests`.
final class CountingHAL: Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: (attaches: 0, cleanDetaches: 0))
    private let inputs = OSAllocatedUnfairLock(initialState: [DeviceInput]())

    var attaches: Int { counts.withLock { $0.attaches } }
    var isFree: Bool { counts.withLock { $0.attaches == $0.cleanDetaches } }

    /// The live environment with this HAL, the access granted, and a watchdog limit of 60 s, so
    /// a device with no records is never lost in a test.
    var environment: CaptureEnvironment {
        let duo = InputDevice(
            uid: "duo", name: "Duo", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [2],
            latency: 0)!
        var environment = CaptureEnvironment.live
        environment.hal = DeviceHAL(
            lookUp: { $0 == duo.uid ? (7, duo) : nil },
            attach: { [counts, inputs] input in
                counts.withLock { $0.attaches += 1 }
                inputs.withLock { $0.append(input) }
                return {
                    counts.withLock { $0.cleanDetaches += 1 }
                    return true
                }
            }, watchDevices: { _ in { true } })
        environment.microphoneAccess = { nil }
        environment.silenceLimit = noWatchdog
        environment.firstRecordLimit = noWatchdog
        return environment
    }

    /// Pushes `seconds` of stereo silence into the ring of the last attached input, as the IOProc
    /// does: records of 10 ms from now. The device writer drains them into the take. The writer
    /// attaches on its queue after the transport change, so it first waits (60 s limit) until an
    /// input is attached and not detached.
    @MainActor func feed(seconds: Double) async {
        await until("no input is attached") { !isFree }
        guard let input = inputs.withLock({ $0.last }) else {
            Issue.record("No input is attached")
            return
        }
        input.ring.setRate(48_000)
        let start = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        for n in 0..<Int(seconds * 100) {
            var time = AudioTimeStamp()
            time.mSampleTime = Double(n * 480)
            time.mHostTime = AudioConvertNanosToHostTime(start + UInt64(n) * 10_000_000)
            time.mRateScalar = 1
            time.mFlags = [.sampleTimeValid, .hostTimeValid]
            var samples = [Float](repeating: 0, count: 960)
            samples.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                var output = AudioBufferList()
                withUnsafePointer(to: time) { time in
                    _ = CaptureRing.ioProc(7, time, &list, time, &output, time, input.ring.context)
                }
            }
        }
    }
}

/// Counts the package writes of a studio. Each write still goes to the disk.
final class SaveCounter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var writes: Int { count.withLock { $0 } }

    @MainActor init(_ studio: Studio) {
        let save = studio.environment.saveSession
        studio.environment.saveSession = { [count] session, lock throws(SessionFileError) in
            count.withLock { $0 += 1 }
            return try await save(session, lock)
        }
    }
}

/// Holds the first caller of `wait` until `open`, with a limit. It polls, so it blocks no thread
/// of the concurrency pool. Later callers pass. A copy of the gate of `DirigibleAudioTests`: the
/// test targets share no code.
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
