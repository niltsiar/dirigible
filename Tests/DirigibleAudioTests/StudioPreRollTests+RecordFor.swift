import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The timed pre-roll take of `dirigible record` and the `record` tool (decision 0070, criterion
/// P14), on the host clock.
extension StudioPreRollTests {
    /// A take of 2 s at T = 2 s. The input runs from H_T - 0.5 s for 3 s, and `mic` delivers each
    /// record 200 ms after its host time. The clip is the 2 s from T, so the stop waits for H_T, not
    /// for 2 s from the start return, and for the frames in flight.
    @Test(arguments: [1, 2])
    func recordForCountsFromT(preRoll: Int) async throws {
        let studio = try await studio()
        studio.environment.hostNanos = hostNanosNow
        let input = SyntheticInput(hal, "mic")
        input.play(
            records(
                [sine(seconds: 3, rate: 48_000)], layout: [1], rate: 48_000, frames: 480,
                hostStart: takeStart - 500_000_000),
            pace: .lagging(nanos: 200_000_000), takeStartIn: package.url)

        let result = try await studio.record(armed: ["t1"], playhead: 96_000, for: .seconds(2), preRoll: preRoll)
        await input.wait()

        #expect(result.end == .requested && result.gaps == [:])
        let clip = try #require(takeClip(studio))
        #expect(clip.start == 96_000 && clip.offset == 24_000 && clip.length == 96_000, "\(clip)")
    }
}
