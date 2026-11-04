import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The raw sweep job at open, of a take that a build before decision 0071 finalized (C5, C17,
/// C19): the job reads the WAV peak off the main actor, appends the finalize record, and removes
/// the CAF.
@MainActor
struct RawSweepTests {
    static let segment = SegmentName(stem: "take1-1-1")!

    /// The steps of the job that the seam saw, and a hold of the job at the step `at`.
    final class Hold: @unchecked Sendable {
        let at: RawSweepStep
        let gate = AsyncGate()
        private let lock = NSLock()
        private var steps: [RawSweepStep] = []

        init(at: RawSweepStep) { self.at = at }

        var seen: [RawSweepStep] { lock.withLock { steps } }

        func step(_ step: RawSweepStep) async {
            lock.withLock { steps.append(step) }
            if step == at { await gate.wait() }
        }
    }

    /// An old take: take 1 with a 4 s segment (3 WAV blocks) whose float peak is 4.0, finalized
    /// and saved with no sweep, and with no finalize record in its sidecar. Returns the package
    /// and the record that the finalize wrote.
    static func oldTake() async throws -> (TakePackage, FinalizeRecord) {
        let package = try TakePackage()
        try package.segment(samples: sine(seconds: 4, rate: 48_000).map { $0 * 4 })
        let url = package.url
        try await offMainActor {
            let outcome = completeTake(of: try Session(contentsOf: url), lock: try PackageLock(url), level: false) {
                session throws(SessionFileError) in try session.write(to: url)
            }
            #expect(outcome.error == nil)
        }
        let record = try #require(try Self.record(in: package))
        let sidecar = package.capture.appending(path: segment.sidecarName)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: sidecar.path)[.size] as? Int)
        try #require(truncate(sidecar.path, off_t(size - Sidecar.encode(record).count)) == 0)
        try #require(try Self.record(in: package) == nil)
        return (package, record)
    }

    static func record(in package: TakePackage) throws -> FinalizeRecord? {
        try Sidecar.decode(Data(contentsOf: package.capture.appending(path: segment.sidecarName)))?.finalized
    }

    static func hasCAF(_ package: TakePackage) -> Bool {
        FileManager.default.fileExists(atPath: package.capture.appending(path: segment.cafName).path)
    }

    @Test func anOpenReturnsBeforeTheSweepReadsTheCAF() async throws {
        let (package, written) = try await Self.oldTake()
        #expect(written.conversionGain != .zero, "the peak of 4.0 gives a clip gain")
        let hold = Hold(at: .block(2))
        defer { hold.gate.open() }

        let studio = try await Studio.open(package.url)
        studio.environment.beforeRawStep = { await hold.step($0) }
        await hold.gate.entered()

        #expect(Self.hasCAF(package), "the job holds at block 2 of the WAV read with the CAF")
        #expect(try Self.record(in: package) == nil, "no record before the read ends")
        hold.gate.open()
        await studio.rawSweep

        #expect(!Self.hasCAF(package), "the sweep removes the CAF of the old take")
        let record = try #require(try Self.record(in: package))
        #expect(record.cafFrames == written.cafFrames && record.sourceRate == written.sourceRate)
        #expect(abs(record.conversionGain.dB - written.conversionGain.dB) < 1e-4, "the gain of the finalize")
        await studio.settle()
    }
}
