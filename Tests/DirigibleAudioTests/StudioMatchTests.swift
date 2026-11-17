import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A studio on a package with track "ref" (clip "R" of file "r") and tracks "t1", "t2", ...
/// (clips "T1", "T2", ... of files "t1", "t2", ...). It keeps the package folder while it lives.
@MainActor
final class MatchFixture {
    let package: MixPackage
    let studio: Studio

    init(
        reference: [Float], start: Frames = 0, targets: [[Float]], edit: (inout Session) throws -> Void = { _ in }
    ) async throws {
        package = try MixPackage()
        try package.addFile("r", channels: [reference])
        try package.addTrack("ref", clip: "R", file: "r", start: start, offset: 0, length: Frames(reference.count))
        for (index, target) in targets.enumerated() {
            let number = index + 1
            try package.addFile(FileID("t\(number)"), channels: [target])
            try package.addTrack(
                TrackID("t\(number)"), clip: ClipID("T\(number)"), file: FileID("t\(number)"), start: 0, offset: 0,
                length: Frames(target.count))
        }
        try edit(&package.session)
        try package.session.write(to: package.url)
        studio = try await Studio.open(package.url)
    }

    func match(_ track: TrackID = "t1") throws -> VoiceMatch { try #require(studio.session.track(track)?.match) }

    @discardableResult
    func matchVoice(range: Range<Frames>? = nil, _ tracks: Set<TrackID> = ["t1"], amount: Int? = nil) async throws
        -> [TrackID: VoiceMatch]
    {
        try await studio.matchVoice(
            reference: "R", range: range, tracks: tracks, amount: amount.flatMap(VoiceMatch.Amount.init), agent: nil)
    }
}

/// Criteria C6, C10, C11, C19, and C20 of decision 0074: `Studio.matchVoice` and the match edits.
@MainActor
struct StudioMatchTests {
    static let rising = shapedNoise(slope: 6)
    static let falling = shapedNoise(slope: -6, seed: 11)
    static let flat = shapedNoise(slope: 0, seed: 13)

    /// 9.9 s of voice refuses with 9 s and names the side; 10.0 s passes. A refusal keeps the
    /// session revision and stores nothing.
    @Test(arguments: [(9.9, true), (10.0, true), (9.9, false), (10.0, false)])
    func tooLittleVoice(seconds: Double, onReference: Bool) async throws {
        let (short, long) = (repeated(Self.flat, seconds: seconds), repeated(Self.rising, seconds: 30))
        let fixture = try await MatchFixture(
            reference: onReference ? short : repeated(Self.flat, seconds: 30), targets: [onReference ? long : short])
        let revision = fixture.studio.sessionRevision
        if seconds < 10 {
            await #expect(throws: StudioError.tooLittleVoice(side: onReference ? .reference : .track("t1"), seconds: 9))
            {
                try await fixture.matchVoice()
            }
            #expect(fixture.studio.sessionRevision == revision && fixture.studio.session.track("t1")?.match == nil)
        } else {
            try await fixture.matchVoice()
            #expect(try fixture.match().reference == "r")
        }
    }

    /// A music or effects track is left out; with no target left the match refuses.
    @Test func musicTrackIsLeftOut() async throws {
        let target = repeated(Self.rising, seconds: 20)
        let fixture = try await MatchFixture(reference: repeated(Self.flat, seconds: 20), targets: [target, target]) {
            try $0.setRole(.music, tracks: ["t2"])
        }
        let matches = try await fixture.matchVoice(["t1", "t2"])
        #expect(Set(matches.keys) == ["t1"] && fixture.studio.session.track("t2")?.match == nil)
    }

    /// The track of the reference clip is left out next to a real target and keeps no match; named
    /// alone, it refuses with no target and changes nothing.
    @Test func referenceTrackIsLeftOut() async throws {
        let fixture = try await MatchFixture(
            reference: repeated(Self.flat, seconds: 20), targets: [repeated(Self.rising, seconds: 20)])
        let matches = try await fixture.matchVoice(["ref", "t1"])
        #expect(Set(matches.keys) == ["t1"] && fixture.studio.session.track("ref")?.match == nil)

        let revision = fixture.studio.sessionRevision
        await #expect(throws: StudioError.noTargetTrack) { try await fixture.matchVoice(["ref"]) }
        #expect(fixture.studio.sessionRevision == revision)
    }

    @Test func noTargetRefused() async throws {
        let fixture = try await MatchFixture(
            reference: repeated(Self.flat, seconds: 20), targets: [repeated(Self.rising, seconds: 20)]
        ) { try $0.setRole(.effects, tracks: ["t1"]) }
        let revision = fixture.studio.sessionRevision
        await #expect(throws: StudioError.noTargetTrack) { try await fixture.matchVoice() }
        #expect(fixture.studio.sessionRevision == revision)
    }

    /// A reference of 40 s: 20 s rising 6 dB per decade, then 20 s falling, at one loudness (else
    /// the quieter half fails the relative gate). A range over the first 20 s gives the curve of a
    /// clip of only those 20 s; the whole clip differs at 8 kHz.
    @Test func rangeReadsOnlyItsFrames() async throws {
        var (first, second) = (repeated(Self.rising, seconds: 20), repeated(Self.falling, seconds: 20))
        let difference = try Self.loudness(first) - Self.loudness(second)
        let quieter = Float(pow(10, -abs(difference) / 20))
        if difference > 0 { first = first.map { $0 * quieter } } else { second = second.map { $0 * quieter } }
        let reference = first + second
        let target = Self.bursts(Self.flat, seconds: 40)
        let ranged = try await MatchFixture(reference: reference, targets: [target])
        try await ranged.matchVoice(range: 0..<960_000)
        let alone = try await MatchFixture(reference: first, targets: [target])
        try await alone.matchVoice()
        let whole = try await MatchFixture(reference: reference, targets: [target])
        try await whole.matchVoice()
        let (r, a, w) = (
            try ranged.match().curve.decibels, try alone.match().curve.decibels, try whole.match().curve.decibels
        )
        let differences = zip(r, a).map { abs($0 - $1) }
        #expect(differences.max()! <= 0.1, "\(differences)")
        print(
            "StudioMatchTests: loudness of the halves \(difference) LU apart; 8 kHz: whole \(w[21]) dB, range \(r[21]) dB"
        )
        #expect(abs(w[21] - r[21]) > 3, "8 kHz: whole \(w[21]), range \(r[21])")
    }

    /// The 10 s minimum counts only the range: 9.9 s refuses with 9 s, 10.0 s passes.
    @Test(arguments: [9.9, 10.0])
    func rangeCountsItsVoice(seconds: Double) async throws {
        let fixture = try await MatchFixture(
            reference: repeated(Self.flat, seconds: 30), targets: [repeated(Self.rising, seconds: 30)])
        let range = Frames(48_000)..<Frames(48_000 + Int(seconds * 48_000))
        if seconds < 10 {
            await #expect(throws: StudioError.tooLittleVoice(side: .reference, seconds: 9)) {
                try await fixture.matchVoice(range: range)
            }
        } else {
            try await fixture.matchVoice(range: range)
            #expect(try fixture.match().reference == "r")
        }
    }

    /// A range that ends at the clip end passes; one frame past it refuses with the clip span.
    @Test func rangeOutsideTheClipRefused() async throws {
        let fixture = try await MatchFixture(
            reference: repeated(Self.flat, seconds: 20), start: 48_000, targets: [repeated(Self.rising, seconds: 30)])
        let revision = fixture.studio.sessionRevision
        await #expect(throws: StudioError.rangeOutsideReference(clip: 48_000..<1_008_000)) {
            try await fixture.matchVoice(range: 48_000..<1_008_001)
        }
        #expect(fixture.studio.sessionRevision == revision)
        try await fixture.matchVoice(range: 48_000..<1_008_000)
        #expect(try fixture.match().amount == VoiceMatch.defaultAmount)
    }

    /// A match of two tracks is one undo entry, each track with its own curve at amount 75; one
    /// Undo gives both tracks no match.
    @Test func oneUndoEntry() async throws {
        let fixture = try await MatchFixture(
            reference: repeated(Self.flat, seconds: 20),
            targets: [repeated(Self.rising, seconds: 20), repeated(Self.falling, seconds: 20)])
        let revision = fixture.studio.sessionRevision
        try await fixture.matchVoice(["t1", "t2"])
        #expect(fixture.studio.sessionRevision == revision + 1)
        let (one, two) = (try fixture.match("t1"), try fixture.match("t2"))
        #expect(one.amount == VoiceMatch.defaultAmount && two.amount == VoiceMatch.defaultAmount)
        #expect(one.curve != two.curve)
        try fixture.studio.undo()
        #expect(fixture.studio.session.track("t1")?.match == nil && fixture.studio.session.track("t2")?.match == nil)
    }

    /// A replace keeps the amount of the track, turns the bypass off, and is one entry: Undo gives
    /// the old match back, equal.
    @Test func replaceIsOneEntry() async throws {
        let fixture = try await MatchFixture(
            reference: repeated(Self.flat, seconds: 20), targets: [repeated(Self.rising, seconds: 20)])
        let studio = fixture.studio
        try await fixture.matchVoice()
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMatchAmount(VoiceMatch.Amount(40)!, tracks: ["t1"])
            try session.setMatchBypassed(true, tracks: ["t1"])
        }
        let old = try fixture.match()
        let revision = studio.sessionRevision
        try await fixture.matchVoice()
        let new = try fixture.match()
        #expect(studio.sessionRevision == revision + 1)
        #expect(new.amount.percent == 40 && !new.isBypassed)
        try studio.undo()
        #expect(try fixture.match() == old)
    }

    /// C6 and C19: 60 s of bursts that rise 6 dB per decade, matched to a flat reference, play at
    /// the loudness of the bypassed track within 0.5 LU at amounts 1, 75, and 100.
    @Test(arguments: [1, 75, 100])
    func onAndOffKeepTheLoudness(amount: Int) async throws {
        let bursts = Self.bursts(Self.rising, seconds: 60)
        let fixture = try await MatchFixture(reference: repeated(Self.flat, seconds: 30), targets: [bursts])
        try await fixture.matchVoice(amount: amount)
        var session = fixture.studio.session
        let on = try Self.loudness(fixture.package, session)
        try session.setMatchBypassed(true, tracks: ["t1"])
        let off = try Self.loudness(fixture.package, session)
        let curve = try fixture.match().curve.decibels
        print(
            "StudioMatchTests: amount \(amount), on \(on) LUFS, off \(off) LUFS, change \(on - off) LU, "
                + "curve \(curve.min()!) to \(curve.max()!) dB")
        #expect(abs(on - off) <= 0.5)
        #expect(curve.max()! - curve.min()! >= 6, "the fixture has a curve")
    }

    /// `seconds` of `noise` in bursts of 2 s, with hiss 40 dB under the burst RMS in the 2 s
    /// pauses, so the noise estimate of a target is low and no noise guard stops a boost.
    static func bursts(_ noise: [Float], seconds: Double) -> [Float] {
        let samples = repeated(noise, seconds: seconds)
        let rms = sqrt(samples.map { Double($0 * $0) }.reduce(0, +) / Double(samples.count))
        var hiss = ProbeNoise()
        // ProbeNoise is uniform from -1 to 1: an RMS of 1 / sqrt(3).
        let level = Float(rms * 0.01 * sqrt(3))
        return samples.enumerated().map { $0 / 48_000 % 4 < 2 ? $1 : hiss.next() * level }
    }

    /// The integrated loudness of mono `samples` at 48 kHz.
    static func loudness(_ samples: [Float]) throws -> Double {
        var meter = try #require(LoudnessMeter(sampleRate: 48_000, layout: .mono))
        meter.feed(try pcmBuffer([samples]))
        return try #require(meter.result().integrated).value
    }

    /// The integrated loudness of track t1 through `MixReader`.
    static func loudness(_ package: MixPackage, _ session: Session) throws -> Double {
        let mix = MixReader(package: package.url, session: session, tracks: ["t1"])
        let channels = try package.render(mix, 0..<2_880_000)
        var meter = try #require(LoudnessMeter(sampleRate: 48_000, layout: .stereo))
        meter.feed(try pcmBuffer(channels))
        return try #require(meter.result().integrated).value
    }
}
