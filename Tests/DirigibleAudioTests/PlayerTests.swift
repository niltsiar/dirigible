import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The Player of decision 0016 (timeline-playback criteria 5 to 10), on the real graph in offline
/// manual rendering. Tolerance: ± 1e-6 per sample (no gain).
struct PlayerTests {
    let package: MixPackage
    let forward = Shuttle(direction: .forward, rate: .one)
    let reverse = Shuttle(direction: .reverse, rate: .one)

    /// A mono track with one clip of 96000 distinct frames at timeline 0.
    init() throws {
        package = try MixPackage()
        try package.addFile("f1", channels: [ramp(frames: 100_000)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 96_000)
    }

    func player() -> Player {
        let url = package.url
        return Player(package: { url }, output: .offline, session: package.session)
    }

    func expectEqual(_ out: [[Float]], _ mix: [[Float]], _ comment: Comment) {
        #expect(out.count == 2 && mix.count == 2, comment)
        for (a, b) in zip(out, mix) { #expect(maxError(a, b) <= 1e-6, comment) }
    }

    @Test func forwardPlayEqualsTheMix() async throws {
        let player = player()
        await player.apply(.play(from: 2400, shuttle: forward), number: 1)
        let out = await player.renderOffline(frames: 9600)
        expectEqual(out, try package.mix(2400..<12_000), "L from 2400")
        #expect(maxError(out[0], try package.mix(0..<9600)[0]) > 1e-3, "not the mix from 0")
    }

    @Test func aPlayFromZeroGivesTheMixFromZero() async throws {
        let player = player()
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        expectEqual(await player.renderOffline(frames: 9600), try package.mix(0..<9600), "L from 0")
    }

    @Test func jPlaysTheMixBackward() async throws {
        let player = player()
        await player.apply(.play(from: 24_000, shuttle: reverse), number: 1)
        let out = await player.renderOffline(frames: 9600)
        let mix = try package.mix(14_400..<24_000).map { Array($0.reversed()) }
        expectEqual(out, mix, "J from 24000: output frame i is mix frame 23999 - i")
        #expect(await player.reading().frame == 14_400)
    }

    @Test func lFromTheSameFramePlaysForward() async throws {
        let player = player()
        await player.apply(.play(from: 24_000, shuttle: forward), number: 1)
        expectEqual(await player.renderOffline(frames: 9600), try package.mix(24_000..<33_600), "L from 24000")
        #expect(await player.reading().frame == 33_600)
    }

    @Test func pauseKeepsThePlayheadAndReturnGoesBack() async throws {
        let player = player()
        await player.apply(.play(from: 2400, shuttle: forward), number: 1)
        _ = await player.renderOffline(frames: 7000)
        #expect(await player.reading().frame == 9400)
        await player.apply(.stop, number: 2)
        let reading = await player.reading()
        #expect(reading.frame == 9400 && reading.number == 2 && reading.played == 1)
    }

    @Test func aLateCompletionDoesNotEndTheNextPlay() async throws {
        let player = player()
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        _ = await player.renderOffline(frames: 4800)
        await player.apply(.stop, number: 2)
        await player.apply(.play(from: 48_000, shuttle: forward), number: 3)
        expectEqual(await player.renderOffline(frames: 14_400), try package.mix(48_000..<62_400), "the new play")
        await player.apply(.stop, number: 2)
        expectEqual(await player.renderOffline(frames: 4800), try package.mix(62_400..<67_200), "an old stop")
        let reading = await player.reading()
        #expect(reading.number == 3 && reading.played == 3 && reading.frame == 67_200)
    }

    @Test func anUpdateKeepsTheFeed() async throws {
        let player = player()
        let first = package.session
        var second = first
        try second.place(Clip(id: "c2", file: "f1", start: 0, offset: 4000, length: 96_000), on: "t1")
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        expectEqual(await player.renderOffline(frames: 4800), try package.mix(0..<4800), "before the update")
        await player.update(second, revision: 2)
        await player.update(first, revision: 1)
        let out = await player.renderOffline(frames: 8 * 4800)
        expectEqual(
            slice(out, 4 * 4800..<8 * 4800), try package.mix(24_000..<43_200, session: second),
            "chunks 5 to 8 after the update")
        let reading = await player.reading()
        #expect(reading.number == 1 && reading.frame == 43_200)
    }
}
