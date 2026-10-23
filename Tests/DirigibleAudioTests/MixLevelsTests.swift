import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The window levels of the mix for `silences`, `nearest_pause`, and the duck (decision 0062,
/// criteria C1, C2, C4, and C12), offline through `MixReader`. The fixtures are 1 kHz tones with
/// RMS levels in dBFS (`SpeechActivityTests.tone`); -infinity is digital silence.
struct MixLevelsTests {
    static let threshold = Gain(dB: -40)!

    /// A package with one mono track `t1` of the tone of `parts` from frame 0.
    static func package(_ parts: [(seconds: Double, dBFS: Double)]) throws -> MixPackage {
        let package = try MixPackage()
        let samples = SpeechActivityTests.tone(parts)
        try package.addFile("f1", channels: [samples])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: Frames(samples.count))
        return package
    }

    /// The silences of `range` of `tracks` with a minimum of 500 ms.
    static func silences(
        _ package: MixPackage, _ range: Range<Frames>, tracks: Set<TrackID>? = nil
    ) throws -> [Range<Frames>] {
        try mixLevels(of: tracks, in: package.session, package: package.url, range: range, silence: threshold)
            .series.silences(threshold: threshold, minLength: 24_000, in: range)
    }

    static func seconds(_ start: Double, _ end: Double) -> Range<Frames> {
        Frames(Int(start * 48_000))..<Frames(Int(end * 48_000))
    }

    /// Track t1 sounds at 1 to 2 s, t2 at 3 to 4 s. With t1 muted and t2 soloed, both still count.
    @Test func mixLevelsReadEveryTrackWithMuteAndSoloOff() throws {
        let package = try Self.package([(1, -.infinity), (1, -20), (3, -.infinity)])
        try package.addFile("f2", channels: [SpeechActivityTests.tone([(3, -.infinity), (1, -20), (1, -.infinity)])])
        try package.addTrack("t2", clip: "c2", file: "f2", start: 0, offset: 0, length: 240_000)
        try package.session.setMuted(true, tracks: ["t1"])
        try package.session.setSoloed(true, tracks: ["t2"])
        let found = try Self.silences(package, 0..<240_000)
        #expect(found == [Self.seconds(0, 1), Self.seconds(2, 3), Self.seconds(4, 5)], "\(found)")
    }

    @Test func aTrackListReadsOnlyThoseTracks() throws {
        let package = try Self.package([(1, -.infinity), (1, -20), (3, -.infinity)])
        try package.addFile("f2", channels: [SpeechActivityTests.tone([(3, -.infinity), (1, -20), (1, -.infinity)])])
        try package.addTrack("t2", clip: "c2", file: "f2", start: 0, offset: 0, length: 240_000)
        let found = try Self.silences(package, 0..<240_000, tracks: ["t2"])
        #expect(found == [Self.seconds(0, 3), Self.seconds(4, 5)], "\(found)")
    }

    /// A -20 dBFS tone under an envelope of -60 dB from 2 s to 3 s is silent there.
    @Test func anEnvelopeDipIsASilence() throws {
        let package = try MixPackage()
        try package.addFile("f1", channels: [SpeechActivityTests.tone([(5, -20)])])
        let points: [(Int, Double)] = [(95_999, 0), (96_000, -60), (143_999, -60), (144_000, 0)]
        let envelope = try #require(GainEnvelope(points.map { .init(frame: Frames($0.0), gain: Gain(dB: $0.1)!) }))
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 240_000, envelope: envelope)
        let found = try Self.silences(package, 0..<240_000)
        #expect(found == [Self.seconds(2, 3)], "\(found)")
    }

    /// The library contract of the duck: a missing file is silence and is named.
    @Test func aMissingFileReadsAsSilenceAndIsNamed() throws {
        let package = try Self.package([(2, -20)])
        try package.session.addFile(AudioFile(id: "gone", path: "gone.wav", layout: .mono, length: 96_000))
        try package.addTrack("t2", clip: "c2", file: "gone", start: 96_000, offset: 0, length: 96_000)
        let read = try mixLevels(
            of: nil, in: package.session, package: package.url, range: 0..<192_000, silence: Self.threshold)
        let found = read.series.silences(threshold: Self.threshold, minLength: 24_000, in: 0..<192_000)
        #expect(found == [Self.seconds(2, 4)] && read.faults == ["gone": .missing], "\(found), faults \(read.faults)")
    }

    /// The scan reads past each edge to the end of the run that crosses it, or the session end.
    @Test func theScanReadsPastAnEdgeToTheEndOfTheRun() throws {
        func pause(_ gap: Double) throws -> Pause {
            let package = try Self.package([(2 + gap, -20), (0.3, -.infinity), (5, -20)])
            let at = Frames(96_000)
            let read = try mixLevels(
                of: nil, in: package.session, package: package.url, range: 0..<192_000, silence: Self.threshold)
            return read.series.nearestPause(at: at, window: 96_000, threshold: Self.threshold, minLength: 9_600)
        }
        #expect(try pause(1.9) == .pause(Self.seconds(3.9, 4.2), cut: 194_400), "1.9 s")
        guard case .noPause = try pause(2.1) else {
            Issue.record("2.1 s: \(try pause(2.1))")
            return
        }
        // Loud 0 to 4 s, silent 4 to 7 s, loud 7 to 9 s, silent 9 to 12 s: the session end.
        let package = try Self.package([(4, -20), (3, -.infinity), (2, -20), (3, -.infinity)])
        let first = try Self.silences(package, Self.seconds(0, 5))
        let second = try Self.silences(package, Self.seconds(5, 10))
        #expect(first == [Self.seconds(4, 7)], "page 1: \(first)")
        #expect(second == [Self.seconds(4, 7), Self.seconds(9, 12)], "page 2: \(second)")
    }

    /// The silences of one gap are the same for `from` 0 and `from` 1000.
    @Test func theGridStartsAtFrameZero() throws {
        let package = try Self.package([(2, -20), (1, -.infinity), (2, -20)])
        let zero = try Self.silences(package, 0..<240_000)
        let later = try Self.silences(package, 1_000..<240_000)
        #expect(zero == [Self.seconds(2, 3)] && later == zero, "from 0: \(zero), from 1000: \(later)")
    }

    /// A duck in a scope that starts at frame 1000 over speech: its first run starts at 1000.
    @Test func aRangedDuckCutsItsRunsToTheScope() throws {
        let package = try Self.package([(5, -20)])
        let runs = try speechRuns(
            of: ["t1"], in: package.session, package: package.url, scope: 1_000..<240_000,
            shape: .defaults(sampleRate: 48_000)
        ).runs
        #expect(runs == [Frames(1_000)..<Frames(240_000)], "\(runs)")
    }
}
