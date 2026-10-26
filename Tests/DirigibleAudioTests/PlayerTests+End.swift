import DirigibleCore
import Testing

@testable import DirigibleAudio

/// The end of a play in the feed (run agent-transport, C4). The fixture is in `PlayerTests`.
extension PlayerTests {
    /// The dry restart of an underrun builds a new feed: it keeps the end 19 200.
    @Test func anUnderrunKeepsTheEnd() async throws {
        let player = player()
        await player.apply(.play(from: 2400, shuttle: forward, end: 19_200), number: 1)

        let starved = await player.renderOffline(frames: 19_200, starve: true)
        expectEqual(slice(starved, 0..<14_400), try package.mix(2400..<16_800), "the 3 chunks ahead")
        let out = await player.renderOffline(frames: 4800)

        expectEqual(slice(out, 0..<2400), try package.mix(16_800..<19_200), "the frames to the end")
        #expect(out.allSatisfy { $0[2400...].allSatisfy { $0 == 0 } }, "no mix after the end")
        let reading = await player.reading()
        #expect(reading.ended && reading.frame == 19_200)
    }
}
