import Accelerate
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The sweep of an old take whose WAV saturated (decision 0071, code gate item 2).
extension RawSweepTests {
    /// Runs `body` and fails when it does not return within 30 s.
    static func bounded(_ message: String, _ body: @escaping @MainActor () async -> Void) async {
        let done = StepCounter()
        let task = Task { @MainActor in
            await body()
            _ = done.next()
        }
        await until(limit: .seconds(30), message) { done.calls == 1 }
        if done.calls == 1 { await task.value }
    }

    /// An old take whose CAF peak is 4.0. A WAV of a build before the clip gain saturates at full
    /// scale, so only the CAF has the samples over it: the CAF stays, and the saturated record
    /// lets the next open read no WAV block. A WAV at code 8388606 holds each sample at a quarter
    /// of its level, so the sweep removes the CAF.
    @Test(arguments: [true, false]) func aSaturatedOldWAVKeepsItsCAF(saturated: Bool) async throws {
        let (package, _) = try await Self.oldTake()
        let samples = sine(seconds: 4, rate: 48_000).map { $0 * 4 }
        let peak = vDSP.maximumMagnitude(samples)
        try RawRemovalGateTests.writeWAV(
            saturated ? samples : samples.map { $0 / peak * Float(8_388_606) / 8_388_608 }, in: package)
        let code = try RawRemovalGateTests.wavCode(package)
        try #require(saturated ? code > 8_388_606 : code == 8_388_606, "code \(code)")

        do {
            let studio = try await Studio.open(package.url)
            await Self.bounded("the sweep does not end") { await studio.rawSweep }

            #expect(Self.hasCAF(package) == saturated)
            #expect(try Self.record(in: package) == nil || !saturated, "no finalize record for a saturated WAV")
            if saturated {
                #expect(rawCaptures(of: studio.session, in: package.url) == [Self.segment: .saturated])
            }
            await Self.bounded("the settle does not end") { await studio.settle() }
        }
        guard saturated else { return }

        let again = try await Studio.open(package.url)
        let hold = Hold(at: .turn)
        defer { hold.open() }
        hold.attach(again)
        await Self.bounded("the second sweep does not end") { await again.rawSweep }

        #expect(hold.seen == [.first, .segment(0)], "the second open reads no WAV block: \(hold.seen)")
        #expect(Self.hasCAF(package))
        await Self.bounded("the second settle does not end") { await again.settle() }
    }
}
