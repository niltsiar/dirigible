import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The finalize of a 2 h take (criterion 23). Slow: the take is a 1.4 GB CAF and a 1 GB WAV.
struct FinalizeBenchmark {
    static let takeStart: UInt64 = 1_000_000_000_000
    /// 20 ppm over 48000 Hz: 144 ms of drift in 2 h, so finalize converts from the fitted rate.
    static let realRate = 48_000.96

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func twoHoursFinalizeInUnderOneMinuteWithBoundedMemory() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRecording(
            Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: Self.takeStart, armedTracks: ["t1"]))
        let package = try TemporaryPackage(session)
        let frames = try writeSegment(seconds: 7200, in: package.url)

        let finalize = try measure(dirigibleURL.path, ["take", "finalize", package.path])
        let idle = try measure(dirigibleURL.path, ["take", "finalize", package.path])
        let control = try measure("/bin/dd", ["if=/dev/zero", "of=/dev/null", "bs=256m", "count=1"])

        #expect(finalize.status == 0)
        #expect(finalize.seconds < 60)
        #expect(idle.status == 0)
        #expect(finalize.peakBytes - idle.peakBytes < 64 << 20)
        #expect(control.peakBytes > 256 << 20)
        let capture = try #require(package.read().captures["take1-1-1"])
        #expect(abs(try #require(capture.resampledFromRate) - Self.realRate) < 0.01)
        let length = try #require(package.read().files["take1-1-1"]?.length.count)
        #expect(abs(length - Int((Double(frames) * 48_000 / Self.realRate).rounded())) <= 2)
        print("finalize: \(finalize), no pending take: \(idle), dd: \(control)")
    }

    /// Writes one mono segment of `seconds` at the real rate with the real writer: a 1 kHz sine,
    /// a checkpoint at each second, and one at the last frame. Returns the frame count.
    func writeSegment(seconds: Int, in package: URL) throws -> Int {
        let capture = package.appending(path: "Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        let header = CaptureHeader(
            deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelCount: 1, latency: 0, firstSampleTime: 0, firstHostTimeNanos: Self.takeStart)
        let writer = try SegmentWriter(
            folder: capture, name: SegmentName(take: 1, arm: 1, segment: 1), header: header)
        let block = (0..<48_000).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
        let frames = Int((Double(seconds) * Self.realRate).rounded())
        var written = 0
        func checkpoint(_ frame: Int) throws {
            try writer.checkpoint(
                Checkpoint(
                    fileFrame: Int64(frame), sampleTime: Double(frame),
                    hostTimeNanos: Self.takeStart + UInt64((Double(frame) / Self.realRate * 1e9).rounded())))
        }
        while written < frames {
            try checkpoint(written)
            let count = min(block.count, frames - written)
            try block.withUnsafeBufferPointer { try writer.write($0, frames: count) }
            written += count
        }
        try checkpoint(frames - 1)
        try writer.close()
        return frames
    }

    var dirigibleURL: URL {
        Bundle(for: TemporaryPackage.self).bundleURL.deletingLastPathComponent().appending(path: "dirigible")
    }

    /// The child of `measure` gets no descriptor but standard input, output, and error. Found
    /// by a flaky full-disk test: the finalize child kept its filler file open.
    @Test func aMeasuredChildGetsOnlyTheStandardDescriptors() throws {
        let descriptor = open("/dev/null", O_RDONLY)
        try #require(descriptor > STDERR_FILENO)
        defer { close(descriptor) }

        let inherited = try measure("/bin/sh", ["-c", "test -e /dev/fd/\(descriptor)"])
        let standard = try measure("/bin/sh", ["-c", "test -e /dev/fd/2"])

        #expect(inherited.status == 1)
        #expect(standard.status == 0)
    }

    /// Runs `path` as a child process and returns its exit status, its peak resident memory
    /// (`ru_maxrss` from `wait4`, in bytes on macOS), and its wall time. A run over 300 s is
    /// killed, so a hang cannot stop the suite. The child gets only standard input, output, and
    /// error. A copy of another descriptor keeps a file of a parallel test open: a deleted filler
    /// file keeps its space, and a volume does not detach.
    func measure(_ path: String, _ arguments: [String]) throws -> (status: Int32, peakBytes: Int, seconds: Double) {
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addinherit_np(&actions, descriptor)
        }
        var pid: pid_t = 0
        let start = ContinuousClock.now
        try #require(posix_spawn(&pid, path, &actions, &attributes, argv, environ) == 0)
        var status: Int32 = 0
        var usage = rusage()
        while wait4(pid, &status, WNOHANG, &usage) == 0 {
            if ContinuousClock.now - start > .seconds(300) {
                kill(pid, SIGKILL)
                wait4(pid, &status, 0, &usage)
                Issue.record("\(path) ran for more than 300 s")
                break
            }
            usleep(10_000)
        }
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return ((status >> 8) & 0xff, Int(usage.ru_maxrss), seconds)
    }
}
