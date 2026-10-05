import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Mute and solo C5 (decision 0039): a mute or solo change during play crossfades the first chunk
/// that the Player schedules after the update. Each update comes right after the play starts. The
/// play schedules `Player.depth` chunks, and a tick schedules no more before a pull, so the
/// crossfade chunk is output frames 14,400..<19,200.
extension PlayerTests {
    /// Adds t2 (another ramp), so the mix with t1 muted is not silence. Gives the session before
    /// and after the mute of t1.
    func addSecondTrack() throws -> (old: Session, muted: Session) {
        try package.addFile("f2", channels: [ramp(frames: 100_000, channel: 1)])
        try package.addTrack("t2", clip: "c2", file: "f2", start: 0, offset: 0, length: 96_000)
        var muted = package.session
        try muted.setMuted(true, tracks: ["t1"])
        return (package.session, muted)
    }

    /// Output frame k of n is old x (1 - k/n) + new x k/n.
    func crossfade(_ old: [[Float]], _ new: [[Float]]) -> [[Float]] {
        zip(old, new).map { (a: [Float], b: [Float]) -> [Float] in
            let n = Float(a.count)
            return a.indices.map { (k: Int) -> Float in
                let t = Float(k) / n
                return a[k] * (1 - t) + b[k] * t
            }
        }
    }

    /// Plays from `start`, updates to `session` at once, and pulls 5 chunks.
    func playAndUpdate(to session: Session, from start: Frames = 0, shuttle: Shuttle? = nil) async -> (
        player: Player, out: [[Float]]
    ) {
        let player = player()
        await player.apply(.play(from: start, shuttle: shuttle ?? forward), number: 1)
        #expect(await player.scheduledFrames == 3 * 4800, "the play scheduled 3 chunks")
        await player.update(session, revision: 1)
        return (player, await player.renderOffline(frames: 5 * 4800))
    }

    /// C5 a, b, c, f.
    @Test func aMuteDuringPlayCrossfadesOneChunk() async throws {
        let (old, muted) = try addSecondTrack()
        let (player, out) = await playAndUpdate(to: muted)

        expectEqual(slice(out, 0..<14_400), try package.mix(0..<14_400, session: old), "c: the scheduled chunks")
        let fade = crossfade(
            try package.mix(14_400..<19_200, session: old), try package.mix(14_400..<19_200, session: muted))
        expectEqual(slice(out, 14_400..<19_200), fade, "a: the next chunk crossfades")
        expectEqual(slice(out, 19_200..<24_000), try package.mix(19_200..<24_000, session: muted), "b: the new mix")
        let reading = await player.reading()
        #expect(reading.running && reading.played == 1 && reading.frame == 24_000, "f: the play goes on")
    }

    /// C5 d: a reverse play gives the same crossfade in output order. Output frame i is mix
    /// frame 47,999 - i.
    @Test func aReverseMuteCrossfadesInOutputOrder() async throws {
        let (old, muted) = try addSecondTrack()
        let (_, out) = await playAndUpdate(to: muted, from: 48_000, shuttle: reverse)
        func backward(_ session: Session, _ range: Range<Int>) throws -> [[Float]] {
            let frames = Frames(48_000 - range.upperBound)..<Frames(48_000 - range.lowerBound)
            return try package.mix(frames, session: session).map { Array($0.reversed()) }
        }

        expectEqual(slice(out, 0..<14_400), try backward(old, 0..<14_400), "the scheduled chunks")
        let fade = crossfade(try backward(old, 14_400..<19_200), try backward(muted, 14_400..<19_200))
        expectEqual(slice(out, 14_400..<19_200), fade, "d: the crossfade in output order")
        expectEqual(slice(out, 19_200..<24_000), try backward(muted, 19_200..<24_000), "the new mix")
    }

    /// C5 e: an update with no mute or solo change steps at the chunk boundary, as before.
    @Test func aGainEditDoesNotCrossfade() async throws {
        var louder = try addSecondTrack().old
        try louder.setGain(try #require(Gain(dB: 6)), track: "t1")
        let (_, out) = await playAndUpdate(to: louder)
        expectEqual(slice(out, 14_400..<19_200), try package.mix(14_400..<19_200, session: louder), "e: a step")
    }

    /// C5 e: a track add or remove alone steps; only a change of the heard set of the tracks in both sessions
    /// crossfades.
    @Test(arguments: [true, false])
    func aRemovedTrackDuringPlayDoesNotCrossfade(removed: Bool) async throws {
        let one = package.session
        let two = try addSecondTrack().old
        package.session = removed ? two : one
        let (_, out) = await playAndUpdate(to: removed ? one : two)
        let new = removed ? one : two
        let comment: Comment = removed ? "e: a removed track steps" : "e: an added track steps"
        expectEqual(slice(out, 14_400..<19_200), try package.mix(14_400..<19_200, session: new), comment)
    }

    /// Code gate 1 item 2: the removal of the only soloed track brings the other tracks in, so the
    /// next chunk crossfades. The trigger is the heard set of the tracks in both sessions.
    @Test func aRemovedSoloedTrackCrossfades() async throws {
        var soloed = try addSecondTrack().old
        try soloed.setSoloed(true, tracks: ["t1"])
        var removed = soloed
        try removed.removeTrack("t1")
        package.session = soloed
        let (_, out) = await playAndUpdate(to: removed)
        let fade = crossfade(
            try package.mix(14_400..<19_200, session: soloed), try package.mix(14_400..<19_200, session: removed))
        expectEqual(slice(out, 14_400..<19_200), fade, "the other tracks fade in")
    }

    /// Two flag changes before the next refill crossfade from the mix of the scheduled chunks,
    /// not from the session between the updates. Each update changes the heard set: t1 and t2,
    /// then t2 alone, then t1 alone.
    @Test func twoUpdatesCrossfadeFromTheScheduledMix() async throws {
        let (old, muted) = try addSecondTrack()
        var soloed = muted
        try soloed.setMuted(false, tracks: ["t1"])
        try soloed.setSoloed(true, tracks: ["t1"])
        let player = player()
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        await player.update(muted, revision: 1)
        await player.update(soloed, revision: 2)
        let out = await player.renderOffline(frames: 4 * 4800)
        let fade = crossfade(
            try package.mix(14_400..<19_200, session: old), try package.mix(14_400..<19_200, session: soloed))
        expectEqual(slice(out, 14_400..<19_200), fade, "the crossfade starts at the scheduled mix")
    }

    /// C5 g: the pending crossfade is in the feed, so the dry restart after an underrun keeps it.
    @Test func anUnderrunKeepsAPendingCrossfade() async throws {
        let (old, muted) = try addSecondTrack()
        let player = player()
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        await player.update(muted, revision: 1)

        let starved = await player.renderOffline(frames: 4 * 4800, starve: true)
        expectEqual(slice(starved, 0..<14_400), try package.mix(0..<14_400, session: old), "the 3 old chunks")
        #expect(starved.allSatisfy { $0[14_400...].allSatisfy { $0 == 0 } }, "the node ran dry")
        let out = await player.renderOffline(frames: 2 * 4800)

        let fade = crossfade(
            try package.mix(14_400..<19_200, session: old), try package.mix(14_400..<19_200, session: muted))
        expectEqual(slice(out, 0..<4800), fade, "g: the restart crossfades")
        expectEqual(slice(out, 4800..<9600), try package.mix(19_200..<24_000, session: muted), "then the new mix")
    }

    /// C5 h: a seek after the update makes a new feed, so its first chunk is the new mix.
    @Test func aSeekClearsAPendingCrossfade() async throws {
        let muted = try addSecondTrack().muted
        let player = player()
        await player.apply(.play(from: 0, shuttle: forward), number: 1)
        await player.update(muted, revision: 1)
        await player.apply(.play(from: 24_000, shuttle: forward), number: 2)
        let out = await player.renderOffline(frames: 4800)
        expectEqual(out, try package.mix(24_000..<28_800, session: muted), "h: the new play has no crossfade")
    }
}

extension Player {
    /// Tests only: the output frames that the feed scheduled.
    var scheduledFrames: Int { feed?.scheduled ?? 0 }
}
