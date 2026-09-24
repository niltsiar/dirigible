import CoreAudio
import Foundation
import Testing

@testable import DirigibleAudio

/// The ring order under stress (criterion 22). Slow: `make test-slow`. On x86 it cannot fail for
/// a wrong memory order (probe P10); manual check M10 runs it on arm64 in a release build.
struct CaptureRingStressTests {
    /// A producer thread calls the IOProc with `count` mono records of 96 to 3,936 bytes across a
    /// ring of 0.2 s, and waits while the ring has no room. This thread pops each record and
    /// compares its sample time and its bytes with `memcmp`. `corrupt` changes one sample of that
    /// record before the compare. Returns the checked records and the errors.
    func stress(count: Int, corrupt: Int? = nil) -> (checked: Int, errors: Int) {
        let ring = CaptureRing(capacity: 65_536, rate: 48_000)
        defer { ring.deallocate() }
        var generator = SeededGenerator(seed: 22)
        let pattern = (0..<(1 << 20) + 1_024).map { _ in Float(Int.random(in: -32_768...32_767, using: &generator)) }
        @Sendable func frames(_ index: Int) -> Int { 12 + (index &* 7_919) % 961 }
        @Sendable func offset(_ index: Int) -> Int { (index &* 104_729) & ((1 << 20) - 1) }

        let done = DispatchSemaphore(value: 0)
        let end = Date.now + 600
        Thread {
            pattern.withUnsafeBufferPointer { samples in
                let list = AudioBufferList.allocate(maximumBuffers: 1)
                defer { free(list.unsafeMutablePointer) }
                var time = AudioTimeStamp()
                time.mFlags = validTimes
                var output = AudioBufferList()
                for index in 0..<count {
                    list[0] = AudioBuffer(
                        mNumberChannels: 1, mDataByteSize: UInt32(frames(index) * 4),
                        mData: UnsafeMutableRawPointer(mutating: samples.baseAddress! + offset(index)))
                    time.mSampleTime = Double(index)
                    time.mHostTime = UInt64(index)
                    while !ring.hasRoom(for: list.unsafePointer) {
                        guard Date.now < end else { return }
                    }
                    _ = CaptureRing.ioProc(1, &time, list.unsafePointer, &time, &output, &time, ring.context)
                }
            }
            done.signal()
        }.start()

        var checked = 0
        var errors = 0
        while checked < count, Date.now < end {
            guard let popped = ring.pop(), var record = popped.record else { continue }
            if checked == corrupt { record.buffers[0][0] += 1 }
            let length = frames(checked) * 4
            let same = pattern.withUnsafeBufferPointer { expected in
                record.buffers[0].withUnsafeBytes { bytes in
                    bytes.count == length
                        && memcmp(bytes.baseAddress!, expected.baseAddress! + offset(checked), length) == 0
                }
            }
            if !same || record.sampleTime != Double(checked) { errors += 1 }
            checked += 1
        }
        #expect(done.wait(timeout: .now() + 10) == .success, "the producer did not end")
        return (checked, errors)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func twoMillionRecordsCrossTheRingInOrder() {
        let result = stress(count: 2_000_000)
        #expect(result.checked == 2_000_000)
        #expect(result.errors == 0)
    }

    /// Control: one changed sample gives exactly 1 error, so the compare can fail.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func oneChangedSampleGivesOneError() {
        let result = stress(count: 20_000, corrupt: 1_000)
        #expect(result.checked == 20_000)
        #expect(result.errors == 1)
    }
}
