import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The memory part of criterion 23 on a 600 s take, with the helpers of `FinalizeBenchmark`: the
/// peak of `dirigible take finalize` is less than 64 MB over the peak of a finalize with no pending
/// take. A read of the whole take into memory adds about 115 MB. Slow: the take is a 115 MB CAF.
/// This file holds only slow tests, so a change of a fast CLI test does not add the slow suite to
/// the push (scripts/check-changed.sh).
struct FinalizeMemoryTests {
    static let limit = 64 << 20

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func tenMinutesFinalizeWithBoundedMemory() async throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRecording(
            Recording(
                take: 1, playheadFrame: 0, takeStartHostTimeNanos: FinalizeBenchmark.takeStart, armedTracks: ["t1"]))
        let package = try TemporaryPackage(session)
        let bench = FinalizeBenchmark()
        _ = try bench.writeSegment(seconds: 600, in: package.url)

        let finalize = try await bench.measure(bench.dirigibleURL.path, ["take", "finalize", package.path])
        let idle = try await bench.measure(bench.dirigibleURL.path, ["take", "finalize", package.path])
        let control = try await bench.measure("/bin/dd", ["if=/dev/zero", "of=/dev/null", "bs=256m", "count=1"])

        #expect(finalize.status == 0 && idle.status == 0, "the finalize exits \(finalize.status), idle \(idle.status)")
        #expect(try package.read().files["take1-1-1"] != nil, "the finalize placed the take")
        let over = finalize.peakBytes - idle.peakBytes
        #expect(over < Self.limit, "finalize used \(over >> 20) MB over the idle peak, limit \(Self.limit >> 20) MB")
        #expect(control.peakBytes > 256 << 20, "the dd control used \(control.peakBytes >> 20) MB")
        print("finalize: \(finalize), no pending take: \(idle), dd: \(control)")
    }
}
