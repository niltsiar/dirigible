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

    @Test func anUpdateKeepsTheFeed() async throws { try await updateKeepsTheFeed(holdingThePoolFor: .zero) }

    /// The flake of a full run: synchronous tests of other suites held every thread of the
    /// cooperative pool past the 30 s guard of `renderOffline`, so the waiter and the refill task
    /// waited together, and the render then pulled with no feed (`maxError 0.9536207`).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aFullPoolKeepsTheFeed() async throws { try await updateKeepsTheFeed(holdingThePoolFor: .seconds(32)) }

    /// Plays, renders one chunk, updates the session, and renders 8 chunks. With `hold`, one child
    /// task per pool thread blocks its thread for `hold` right before the 8 chunks. The test task
    /// needs a pool thread too, so it cannot wait until each holder is inside its block: the
    /// render time shows that the pool was held. The group waits for the holders also after a
    /// failure, so no holder blocks the pool for the next test.
    private func updateKeepsTheFeed(holdingThePoolFor hold: Duration) async throws {
        let player = player()
        let first = package.session
        var second = first
        try second.place(Clip(id: "c2", file: "f1", start: 0, offset: 4000, length: 96_000), on: "t1")
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        expectEqual(await player.renderOffline(frames: 4800), try package.mix(0..<4800), "before the update")
        await player.update(second, revision: 2)
        await player.update(first, revision: 1)
        let microseconds = UInt32(hold / .microseconds(1))
        let out = await withTaskGroup(of: Void.self) { holders in
            for _ in 0..<(hold > .zero ? ProcessInfo.processInfo.activeProcessorCount : 0) {
                holders.addTask { usleep(microseconds) }
            }
            let start = ContinuousClock.now
            let out = await player.renderOffline(frames: 8 * 4800)
            if hold > .zero {
                #expect(ContinuousClock.now - start > .seconds(30), "the pool was held past the old deadline")
            }
            return out
        }
        expectEqual(
            slice(out, 4 * 4800..<8 * 4800), try package.mix(24_000..<43_200, session: second),
            "chunks 5 to 8 after the update")
        let reading = await player.reading()
        #expect(reading.number == 1 && reading.frame == 43_200)
    }

    @Test(arguments: [(Shuttle.Rate.two, 2.0), (.four, 4.0), (.half, 0.5), (.one, 1.0)])
    func aRateMovesThePlayheadAtThatRate(rate: Shuttle.Rate, factor: Double) async throws {
        let player = player()
        await player.apply(.play(from: 1000, shuttle: Shuttle(direction: .forward, rate: rate)), number: 1)
        let out = await player.renderOffline(frames: 9600)
        #expect(await player.reading().frame == Frames(1000 + Int(9600 * factor)))
        let mix = try package.mix(0..<50_000)
        for channel in 0..<2 {
            let expected = (0..<9600).map { i -> Float in
                let position = 1000 + Double(i) * factor
                let low = Int(position)
                let fraction = Float(position - Double(low))
                return mix[channel][low] + fraction * (mix[channel][low + 1] - mix[channel][low])
            }
            #expect(maxError(out[channel], expected) <= 1e-6, "output frame i is mix frame 1000 + \(factor) i")
        }
    }

    @Test func jAtTwiceTheRatePlaysEveryOtherFrameBackward() async throws {
        let player = player()
        await player.apply(.play(from: 48_000, shuttle: Shuttle(direction: .reverse, rate: .two)), number: 1)
        let out = await player.renderOffline(frames: 9600)
        let mix = try package.mix(0..<48_000)
        let expected = (0..<9600).map { mix[0][47_999 - 2 * $0] }
        #expect(maxError(out[0], expected) <= 1e-6 && maxError(out[1], expected) <= 1e-6)
        #expect(await player.reading().frame == 28_800)
    }

    @Test func playStopsAtTheEndOfTheMaterial() async throws {
        let player = player()
        await player.apply(.play(from: 95_000, shuttle: forward), number: 1)
        let out = await player.renderOffline(frames: 9600)
        expectEqual(slice(out, 0..<1000), try package.mix(95_000..<96_000), "the last 1000 frames")
        var reading = await player.reading()
        #expect(reading.ended && reading.frame == 96_000)
        await player.apply(.play(from: 1000, shuttle: reverse), number: 2)
        _ = await player.renderOffline(frames: 9600)
        reading = await player.reading()
        #expect(reading.ended && reading.frame == 0)
    }

    /// A refill that comes late (a slow disk): the node runs dry for one chunk, and its time goes
    /// on. The playhead stays on the frame that the user hears, and the next chunk plays the
    /// frames after the last heard frame. Found by the code gate.
    @Test func anUnderrunKeepsThePlayheadOnTheHeardFrame() async throws {
        let player = player()
        await player.apply(.play(from: 2400, shuttle: forward), number: 1)

        let starved = await player.renderOffline(frames: 4 * 4800, starve: true)
        expectEqual(slice(starved, 0..<14_400), try package.mix(2400..<16_800), "the 3 chunks ahead")
        #expect(starved.allSatisfy { $0[14_400...].allSatisfy { $0 == 0 } }, "the node ran dry")
        let out = await player.renderOffline(frames: 4800)

        expectEqual(out, try package.mix(16_800..<21_600), "the chunk after the last heard frame")
        #expect(await player.reading().frame == 21_600)
    }

    @Test func aPlayWithFramesLeftIsNotEnded() async throws {
        let player = player()
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        _ = await player.renderOffline(frames: 9600)
        let reading = await player.reading()
        #expect(!reading.ended && reading.frame == 9600)
    }

    /// A file that does not open because the process has no free descriptor stops the play with
    /// its own cause at the refill, and the file gets no media fault. The open of f2 gives
    /// EMFILE. Control: an open that works plays with no stop. Found by the code gate (sibling
    /// of item 2).
    @Test(arguments: [true, false])
    func noFreeDescriptorStopsThePlay(fails: Bool) async throws {
        try package.addFile("f2", channels: [ramp(frames: 24_000, channel: 1)])
        try package.addTrack("t2", clip: "c2", file: "f2", start: 0, offset: 0, length: 24_000)
        let url = package.url
        let player = Player(
            package: { url }, output: .offline, session: package.session,
            open: { file, clips, rate throws(POSIXError) in
                if fails && file.id == "f2" { throw POSIXError(.EMFILE) }
                return try openMedia(file, in: clips, rate: rate)
            })
        await player.apply(.play(from: 0, shuttle: forward), number: 1)

        let reading = await player.reading()
        #expect(reading.stop == (fails ? .noFreeDescriptor(Int(EMFILE)) : nil))
        #expect(reading.faults == [:], "not a fault of the file")
    }
}
