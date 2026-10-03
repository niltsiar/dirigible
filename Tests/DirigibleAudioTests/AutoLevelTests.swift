import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Run 8b criteria 1 to 4: `autoLevel` sets `clipTarget - measured`, clamped to ±20 dB (decisions
/// 0008 and 0031). A -30 dBFS sine reads -30 LUFS in stereo and -33 LUFS in mono.
struct AutoLevelTests {
    /// Records an issue that starts with `label` when the gain of `clip` is not within `tolerance`.
    static func expectGain(
        _ session: Session, _ clip: ClipID, _ expected: Double, tolerance: Double = 0.1, _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let gain = session.clip(clip)?.clip.gain.dB
        let near = gain.map { abs($0 - expected) <= tolerance } ?? false
        #expect(
            near, "\(label): gain \(gain.map { "\($0)" } ?? "nil"), not \(expected)", sourceLocation: sourceLocation)
    }

    @Test func eachClipGetsTheTargetOfItsLayout() throws {
        let package = try MixPackage()
        try package.addFile("s", channels: tone([(20, -30)]))
        try package.addFile("m", channels: tone([(20, -30)], layout: .mono))
        try package.addTrack("t1", layout: .stereo, clip: "cs", file: "s", start: 0, offset: 0, length: 960_000)
        try package.addTrack("t2", layout: .mono, clip: "cm", file: "m", start: 0, offset: 0, length: 960_000)
        let (session, levels) = autoLevel(["cs", "cm"], .eachClip, of: package.session, in: package.url)
        Self.expectGain(session, "cs", 14, "stereo target")
        Self.expectGain(session, "cm", 14, "mono target")
        #expect(levels.count == 2, "levels: \(levels)")
        for id: ClipID in ["cs", "cm"] {
            guard case .leveled(_, let gain) = levels[id] else {
                Issue.record("level of \(id): \(String(describing: levels[id]))")
                continue
            }
            #expect(gain == session.clip(id)?.clip.gain, "level gain of \(id): \(gain)")
        }
    }

    @Test func gainIsClampedAtTwentyDecibels() throws {
        let package = try MixPackage()
        try package.addFile("quiet", channels: tone([(20, -50)]))
        // A full-scale 10 kHz square wave: the K-weighting shelf adds about 4 dB.
        let square = (0..<960_000).map { Float(sin(2 * .pi * 10_000 * Double($0) / 48_000) >= 0 ? 0.999 : -0.999) }
        try package.addFile("loud", channels: [square, square])
        try package.addTrack("t1", layout: .stereo, clip: "cq", file: "quiet", start: 0, offset: 0, length: 960_000)
        try package.addTrack("t2", layout: .stereo, clip: "cl", file: "loud", start: 0, offset: 0, length: 960_000)
        let loud = try #require(package.session.clip("cl")?.clip)
        let reading = try clipLoudness(loud, in: package.session, package: package.url).loudness.integrated
        #expect((reading?.value ?? -100) > -4, "square reading: \(String(describing: reading))")
        let (session, _) = autoLevel(["cq", "cl"], .eachClip, of: package.session, in: package.url)
        Self.expectGain(session, "cq", 20, tolerance: 0.001, "clamp at +20")
        Self.expectGain(session, "cl", -20, tolerance: 0.001, "clamp at -20")
    }

    @Test func aClipWithNoMeasurementKeepsItsGain() throws {
        let package = try MixPackage()
        try package.addFile("silent", channels: tone([(20, -.infinity)]))
        try package.addFile("gone", channels: tone([(20, -30)]))
        try package.addTrack("t1", layout: .stereo, clip: "cs", file: "silent", start: 0, offset: 0, length: 960_000)
        try package.addTrack("t2", layout: .stereo, clip: "cg", file: "gone", start: 0, offset: 0, length: 960_000)
        try package.session.setGain(Gain(dB: 3.5)!, clip: "cs")
        try package.session.setGain(Gain(dB: -2)!, clip: "cg")
        try FileManager.default.removeItem(at: package.url.appending(path: "\(clipsFolderName)/gone.wav"))
        let (session, levels) = autoLevel(["cs", "cg"], .eachClip, of: package.session, in: package.url)
        Self.expectGain(session, "cs", 3.5, tolerance: 0, "silence keeps its gain")
        Self.expectGain(session, "cg", -2, tolerance: 0, "missing file keeps its gain")
        #expect(levels["cs"] == .noMeasurement, "silence level: \(String(describing: levels["cs"]))")
        #expect(levels["cg"] == .unreadable, "missing level: \(String(describing: levels["cg"]))")
    }

    /// Track t1 (stereo): A at -30 dBFS with +2 dB, B at -24 dBFS, and D at -18 dBFS, which is not
    /// in the set. Track t2 (mono): C at -30 dBFS. The union of A and B with their gains reads about
    /// -25.56 LUFS.
    @Test func equallyPerTrackKeepsTheDifferencesOnATrack() throws {
        let package = try MixPackage()
        try package.addFile("a", channels: tone([(20, -30)]))
        try package.addFile("b", channels: tone([(20, -24)]))
        try package.addFile("d", channels: tone([(20, -18)]))
        try package.addFile("c", channels: tone([(20, -30)], layout: .mono))
        try package.addTrack("t1", layout: .stereo, clip: "A", file: "a", start: 0, offset: 0, length: 960_000)
        try package.session.place(
            Clip(id: "B", file: "b", start: 960_000, offset: 0, length: 960_000), on: "t1")
        try package.session.place(
            Clip(id: "D", file: "d", start: 1_920_000, offset: 0, length: 960_000), on: "t1")
        try package.session.setGain(Gain(dB: 2)!, clip: "A")
        try package.addTrack("t2", layout: .mono, clip: "C", file: "c", start: 0, offset: 0, length: 960_000)
        let (session, levels) = autoLevel(["A", "B", "C"], .equallyPerTrack, of: package.session, in: package.url)
        Self.expectGain(session, "A", 11.56, "per track A")
        Self.expectGain(session, "B", 9.56, "per track B")
        Self.expectGain(session, "C", 14, "per track C")
        Self.expectGain(session, "D", 0, tolerance: 0, "per track D not in the set")
        #expect(levels["D"] == nil, "per track D level: \(String(describing: levels["D"]))")
    }
}
