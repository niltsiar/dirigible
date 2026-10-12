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

/// Run 2026-10-12-autolevel-fader C6, C7, and C14: the 0.05 dB tolerance and the level report.
extension AutoLevelTests {
    /// Track t1 (stereo): A at -30 dBFS with +2 dB and B at -24 dBFS. A per-track level leaves a
    /// float residue in `base + delta` when the tolerance is missing.
    @Test func aSecondLevelPerTrackChangesNothing() throws {
        let package = try MixPackage()
        try package.addFile("a", channels: tone([(20, -30)]))
        try package.addFile("b", channels: tone([(20, -24)]))
        try package.addTrack("t1", layout: .stereo, clip: "A", file: "a", start: 0, offset: 0, length: 960_000)
        try package.session.place(Clip(id: "B", file: "b", start: 960_000, offset: 0, length: 960_000), on: "t1")
        try package.session.setGain(Gain(dB: 2)!, clip: "A")
        let first = autoLevel(["A", "B"], .equallyPerTrack, of: package.session, in: package.url).session
        AutoLevelTests.expectGain(first, "B", 9.56, "first level B")
        let (second, levels) = autoLevel(["A", "B"], .equallyPerTrack, of: first, in: package.url)
        let same = second == first
        #expect(same, "second per-track level: A \(gainText(second, "A")), B \(gainText(second, "B"))")
        #expect(LevelReport(levels, before: first).changed == 0, "second per-track level: changed count")
    }

    /// One stereo clip of a -30 dBFS tone. A first level gives the exact gain `leveled`.
    @Test func aSmallChangeKeepsTheGain() throws {
        let package = try MixPackage()
        try package.addFile("s", channels: tone([(20, -30)]))
        try package.addTrack("t1", layout: .stereo, clip: "c", file: "s", start: 0, offset: 0, length: 960_000)
        let leveled = try #require(
            autoLevel(["c"], .eachClip, of: package.session, in: package.url).session.clip("c")?.clip.gain.dB)
        for (offset, keeps) in [(0.04, true), (0.06, false)] {
            var session = package.session
            let old = try #require(Gain(dB: leveled + offset))
            try session.setGain(old, clip: "c")
            let (result, levels) = autoLevel(["c"], .eachClip, of: session, in: package.url)
            let gain = result.clip("c")?.clip.gain
            #expect((gain == old) == keeps, "offset \(offset): gain \(String(describing: gain)), old \(old)")
            guard case .leveled(_, let reported) = levels["c"] else {
                Issue.record("offset \(offset): level \(String(describing: levels["c"]))")
                continue
            }
            #expect(
                reported == gain, "offset \(offset): leveled gain \(reported), session gain \(String(describing: gain))"
            )
            #expect(LevelReport(levels, before: session).changed == (keeps ? 0 : 1), "offset \(offset): changed count")
        }
    }

    /// t1: a -36.5 dBFS tone wants +20.5 dB. t2: a -35.5 dBFS tone wants +19.5 dB. t3: the
    /// full-scale square of `gainIsClampedAtTwentyDecibels` wants less than -20 dB.
    @Test func theReportCountsTheClipsAtTheLimit() throws {
        let package = try MixPackage()
        try package.addFile("over", channels: tone([(20, -36.5)]))
        try package.addFile("under", channels: tone([(20, -35.5)]))
        let square = (0..<960_000).map { Float(sin(2 * .pi * 10_000 * Double($0) / 48_000) >= 0 ? 0.999 : -0.999) }
        try package.addFile("loud", channels: [square, square])
        try package.addTrack("t1", layout: .stereo, clip: "co", file: "over", start: 0, offset: 0, length: 960_000)
        try package.addTrack("t2", layout: .stereo, clip: "cu", file: "under", start: 0, offset: 0, length: 960_000)
        try package.addTrack("t3", layout: .stereo, clip: "cl", file: "loud", start: 0, offset: 0, length: 960_000)

        let (first, levels) = autoLevel(["co", "cu"], .eachClip, of: package.session, in: package.url)
        AutoLevelTests.expectGain(first, "co", 20, tolerance: 0.001, "-36.5 dBFS clamp")
        AutoLevelTests.expectGain(first, "cu", 19.5, "-35.5 dBFS gain")
        #expect(
            LevelReport(levels, before: package.session) == LevelReport(changed: 2, atLimit: 1, unmeasured: 0),
            "tones at the +20 dB side: \(LevelReport(levels, before: package.session))")

        let (_, squareLevels) = autoLevel(["cl"], .eachClip, of: package.session, in: package.url)
        #expect(
            LevelReport(squareLevels, before: package.session) == LevelReport(changed: 1, atLimit: 1, unmeasured: 0),
            "square at the -20 dB side: \(LevelReport(squareLevels, before: package.session))")

        let (_, again) = autoLevel(["co"], .eachClip, of: first, in: package.url)
        #expect(
            LevelReport(again, before: first) == LevelReport(changed: 0, atLimit: 1, unmeasured: 0),
            "second level of the clamped clip: \(LevelReport(again, before: first))")
    }

    /// A -36.5 dBFS tone with +19.98 dB wants +20.5 dB. The clamp gives +20 dB, and the tolerance
    /// keeps +19.98 dB, so the clip did not change but is at the limit.
    @Test func aKeptGainNearTheLimitCounts() throws {
        let package = try MixPackage()
        try package.addFile("over", channels: tone([(20, -36.5)]))
        try package.addTrack("t1", layout: .stereo, clip: "co", file: "over", start: 0, offset: 0, length: 960_000)
        try package.session.setGain(Gain(dB: 19.98)!, clip: "co")
        let (leveled, levels) = autoLevel(["co"], .equallyPerTrack, of: package.session, in: package.url)
        AutoLevelTests.expectGain(leveled, "co", 19.98, tolerance: 0, "kept gain")
        #expect(
            LevelReport(levels, before: package.session) == LevelReport(changed: 0, atLimit: 1, unmeasured: 0),
            "kept gain near the limit: \(LevelReport(levels, before: package.session))")
    }

    @Test func theReportCountsTheUnmeasuredClips() throws {
        let package = try MixPackage()
        try package.addFile("silent", channels: tone([(20, -.infinity)]))
        try package.addFile("gone", channels: tone([(20, -30)]))
        try package.addFile("tone", channels: tone([(20, -30)]))
        try package.addTrack("t1", layout: .stereo, clip: "cs", file: "silent", start: 0, offset: 0, length: 960_000)
        try package.addTrack("t2", layout: .stereo, clip: "cg", file: "gone", start: 0, offset: 0, length: 960_000)
        try package.addTrack("t3", layout: .stereo, clip: "ct", file: "tone", start: 0, offset: 0, length: 960_000)
        try FileManager.default.removeItem(at: package.url.appending(path: "\(clipsFolderName)/gone.wav"))
        let (_, levels) = autoLevel(["cs", "cg", "ct"], .eachClip, of: package.session, in: package.url)
        #expect(
            LevelReport(levels, before: package.session) == LevelReport(changed: 1, atLimit: 0, unmeasured: 2),
            "unmeasured clips: \(LevelReport(levels, before: package.session))")
    }

    private func gainText(_ session: Session, _ clip: ClipID) -> String {
        session.clip(clip).map { "\($0.clip.gain.dB)" } ?? "nil"
    }
}
