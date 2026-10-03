import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A stereo session with one clip of the 1 kHz `parts` at timeline 0, and its offline Player.
/// Keep the package: its folder goes with it.
func loudnessPlayer(_ parts: [(seconds: Double, dBFS: Double)]) throws -> (player: Player, package: MixPackage) {
    let package = try MixPackage()
    let signal = tone(parts)
    try package.addFile("f1", channels: signal)
    try package.addTrack(
        "t1", layout: .stereo, clip: "c1", file: "f1", start: 0, offset: 0, length: Frames(signal[0].count))
    let url = package.url
    return (Player(package: { url }, output: .offline, session: package.session), package)
}

/// Run 9b criteria 9, 10, 11, and 20: the Player meters the heard mix of a 1x forward play.
/// The Player renders offline; one pull is one chunk of 4 800 frames (0.1 s).
struct PlayerLoudnessTests {
    let forward = Shuttle(direction: .forward, rate: .one)

    /// The reading after each of `chunks` pulls of one chunk.
    func readings(_ player: Player, chunks: Int) async -> [Player.Reading] {
        var readings: [Player.Reading] = []
        for _ in 0..<chunks {
            _ = await player.renderOffline(frames: 4_800)
            readings.append(await player.reading())
        }
        return readings
    }

    /// A meter fed at render time reads about -25.9 at 2.8 s: its chunks end up to 0.3 s ahead.
    /// The pulls of the test can keep the feed only 1 chunk ahead. So from 2.5 s to 3.0 s each
    /// reading waits for a refill tick, which schedules 3 chunks ahead, as the device clock does.
    @Test func theValueMatchesTheHeardFrame() async throws {
        let (player, package) = try loudnessPlayer([(3, -40), (5, -20)])
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        for chunk in 1...80 {
            _ = await player.renderOffline(frames: 4_800)
            if (25...30).contains(chunk) {
                let ticks = await player.ticks
                // A hang guard: a tick runs each 50 ms.
                let end = ContinuousClock.now + .seconds(10)
                while await player.ticks == ticks, ContinuousClock.now < end {
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(await player.ticks > ticks, "no refill tick at chunk \(chunk)")
            }
            let reading = await player.reading()
            let heard = Double(reading.frame.count) / 48_000
            if heard >= 0.4 - 1e-9 && heard <= 2.9 + 1e-9 {
                expectLUFS(reading.loudness.momentary, -40, "M at \(heard) s")
            } else if heard >= 3.4 - 1e-9 {
                expectLUFS(reading.loudness.momentary, -20, "M at \(heard) s")
            }
        }
        _ = package
    }

    @Test func shuttleDoesNotFeedTheMeter() async throws {
        let (player, package) = try loudnessPlayer([(5, -30), (5, -20)])
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        let played = try #require(await readings(player, chunks: 50).last)
        let integrated = try #require(played.loudness.integrated)
        expectLUFS(integrated, -30, "I of the 1x play")
        var number = 1
        for shuttle in [Shuttle(direction: .forward, rate: .two), Shuttle(direction: .reverse, rate: .one)] {
            number += 1
            await player.apply(.play(from: await player.reading().frame, shuttle: shuttle), number: number)
            for reading in await readings(player, chunks: 10) {
                #expect(
                    reading.loudness.momentary == nil && reading.loudness.shortTerm == nil
                        && reading.loudness.integrated == integrated,
                    "a shuttle play fed the meter: \(shuttle) at \(reading.frame): \(reading.loudness)")
            }
        }
        _ = package
    }

    /// I of 0 to 10 s is about -22.6. With no reset, the play from 0 keeps it near -22.6; with a
    /// reset at each play, the resume reads -20.
    @Test func aPlayFromANewFrameResets() async throws {
        let parts: [(seconds: Double, dBFS: Double)] = [(5, -30), (5, -20)]
        let (player, package) = try loudnessPlayer(parts)
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        _ = await readings(player, chunks: 50)
        await player.apply(.stop, number: 2)
        let stop = await player.reading().frame
        #expect(stop == 240_000, "the stop frame")
        await player.apply(.play(from: stop, shuttle: forward), number: 3)
        let resumed = try #require(await readings(player, chunks: 50).last)
        let whole = try #require(try measure(tone(parts)).integrated)
        expectLUFS(resumed.loudness.integrated, whole.value, "I after the resume")

        await player.apply(.play(from: 0, shuttle: forward), number: 4)
        let again = try #require(await readings(player, chunks: 20).last)
        expectLUFS(again.loudness.integrated, -30, "I of a play from 0 for 2 s")
        _ = package
    }

    /// The node runs dry for 4 chunks at a heard 4.0 s; the starved output holds the 3 chunks
    /// ahead and then zeros. The restart goes on at 4.3 s, so the heard frames skip the dry gap.
    @Test func anUnderrunRestartKeepsTheMeter() async throws {
        let (player, package) = try loudnessPlayer([(6, -30), (4, -20)])
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        var all = await readings(player, chunks: 40)
        let starved = await player.renderOffline(frames: 4 * 4_800, starve: true)
        #expect(starved.allSatisfy { $0[14_400...].allSatisfy { $0 == 0 } }, "the node ran dry")
        var queued: [Int] = []
        for _ in 0..<47 {
            _ = await player.renderOffline(frames: 4_800)
            all.append(await player.reading())
            queued.append(await player.loudnessQueued)
        }
        #expect(queued.allSatisfy { $0 <= Player.depth + 1 }, "the chunk queue: \(queued)")
        let lags = all.map { abs($0.loudness.seconds - Double($0.frame.count) / 48_000) }
        #expect(lags.allSatisfy { $0 <= 0.1 + 1e-9 }, "seconds less the heard time: \(lags.max() ?? 0)")
        for reading in all where reading.frame >= 312_000 {
            expectLUFS(reading.loudness.momentary, -20, "M at \(reading.frame)")
        }
        _ = package
    }
}
