import DirigibleCore
import Foundation
import Testing

@testable import DirigibleTimeline

/// The inspector criteria I1 to I7 (run 11b-2). A 10 s file "fa.wav" at 48 kHz; on t1 the 1 s
/// clips A (0 s), B (2 s), and C (4 s), and on t2 no clip.
struct InspectionTests {
    let second = Frames(48_000)
    var session: Session

    init() throws {
        session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "fa", path: "fa.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.addTrack("t2", name: "T2", layout: .mono)
        for (id, start) in [("A", 0), ("B", 2), ("C", 4)] as [(ClipID, Int)] {
            let frame = Frames(start * 48_000)
            try session.place(Clip(id: id, file: "fa", start: frame, offset: frame, length: second), on: "t1")
        }
    }

    /// The Marks from `from` to `to` seconds on `tracks`.
    func marks(_ from: Double, _ to: Double, _ tracks: Set<TrackID> = ["t1"]) -> Marks {
        Marks(inPoint: Frames(Int(from * 48_000)), outPoint: Frames(Int(to * 48_000)), tracks: tracks)
    }

    func inspect(_ marks: Marks) throws -> ClipInspection {
        try #require(ClipInspection(marks: marks, session: session))
    }

    /// I5: one strict format per field, with no locale (probe P2).
    @Test func typedNumbersParseInOneFormat() {
        let decibels: [(String, Double?)] = [
            ("-6.5", -6.5), ("-6,5", -6.5), (" -3 ", -3), ("\u{2212}3", -3), ("+4", 4), ("0", 0),
            ("6.5.1", nil), ("abc", nil), ("1e3", nil), ("--1", nil), ("1.000,5", nil), ("", nil), (".5", nil),
            ("nan", nil), ("inf", nil),
        ]
        for (text, expected) in decibels {
            #expect(ClipInspection.decibels(text) == expected, "dB of '\(text)'")
        }
        let milliseconds: [(String, Double?)] = [
            ("500", 500), (" 500 ", 500), ("-20", -20), ("+7", 7),
            ("1.500", nil), ("1,500", nil), ("0.5", nil), ("abc", nil), ("1e3", nil), ("", nil),
        ]
        for (text, expected) in milliseconds {
            #expect(ClipInspection.milliseconds(text) == expected, "ms of '\(text)'")
        }
    }

    /// I1: no selection, or a selection with no clip, gives no inspection.
    @Test func noClipsGiveNoInspection() {
        #expect(ClipInspection(marks: Marks(), session: session) == nil, "no Marks")
        #expect(ClipInspection(marks: marks(0, 5, ["t2"]), session: session) == nil, "a range with no clip")
        #expect(ClipInspection(marks: marks(1.2, 1.8), session: session) == nil, "a gap")
    }

    /// I2: one clip shows its name and its values.
    @Test mutating func oneClipShowsItsValues() throws {
        try session.setGain(Gain(dB: -6)!, clip: "A")
        try session.setFades(["A": Fades(fadeIn: 24_000, fadeOut: 0)!])
        let inspection = try inspect(marks(0.2, 0.4))
        #expect(inspection.clips == ["A"])
        #expect(inspection.name == "fa")
        #expect(inspection.gain == .value(Gain(dB: -6)!))
        #expect(inspection.fadeIn == .value(24_000) && inspection.fadeOut == .value(.zero))
    }

    /// I3: equal values on many clips show the value, and no name.
    @Test mutating func equalValuesShowTheValue() throws {
        try session.setGains(["A": Gain(dB: -6)!, "B": Gain(dB: -6)!, "C": Gain(dB: -6)!])
        let fades = Fades(fadeIn: 24_000, fadeOut: 0)!
        try session.setFades(["A": fades, "B": fades, "C": fades])
        let inspection = try inspect(marks(0.5, 4.5))
        #expect(inspection.clips == ["A", "B", "C"] && inspection.name == nil)
        #expect(inspection.gain == .value(Gain(dB: -6)!) && inspection.fadeIn == .value(24_000))
    }

    /// I4: different values show Mixed; equal fades still show their value.
    @Test mutating func differentValuesShowMixed() throws {
        try session.setGain(Gain(dB: -6)!, clip: "A")
        let inspection = try inspect(marks(0.5, 2.5))
        #expect(inspection.clips == ["A", "B"])
        #expect(inspection.gain == .mixed)
        #expect(inspection.fadeIn == .value(.zero) && inspection.fadeOut == .value(.zero))
    }

    /// I6: 0.1 dB to nearest (ties away from 0), clamped to ±20 dB, only the clips that change.
    @Test mutating func aTypedGainSetsEachClipThatChanges() throws {
        func gains(_ dB: Double, _ clips: [ClipID]) -> [ClipID: Gain]? {
            ClipInspection.gains(dB, for: clips, in: session)
        }
        #expect(gains(-6.04, ["A"]) == ["A": Gain(dB: -6.0)!])
        #expect(gains(-6.05, ["A"]) == ["A": Gain(dB: -6.1)!])
        #expect(gains(25, ["A"]) == ["A": Gain(dB: 20)!], "+25 clamps to +20")
        #expect(gains(-25, ["A"]) == ["A": Gain(dB: -20)!])
        #expect(
            gains(try #require(ClipInspection.decibels("99999999999999999999")), ["A"]) == ["A": Gain(dB: 20)!],
            "a huge value, no trap")
        #expect(gains(.infinity, ["A"]) == ["A": Gain(dB: 20)!])

        try session.setGain(Gain(dB: -6)!, clip: "A")
        #expect(gains(-6, ["A", "B"]) == ["B": Gain(dB: -6)!], "A already has -6")
        #expect(gains(-6, ["A"]) == nil, "no change, no edit")
        #expect(gains(-3, ["A", "X"]) == ["A": Gain(dB: -3)!], "a clip that is gone drops out")

        try session.setGain(Gain(dB: -40)!, clip: "C")
        #expect(try inspect(marks(4.2, 4.4)).gain == .value(Gain(dB: -40)!), "a stored value outside the limit shows")
    }

    /// Crossfades F2: a typed fade of many clips skips an edge with a crossfade, and the free edge
    /// of that clip stops at its room (1 s - 480 frames).
    @Test mutating func aFadeOfManyClipsSkipsACrossfadeEdge() throws {
        try session.place(Clip(id: "X", file: "fa", start: second, offset: 200_000, length: second), on: "t1")
        try session.setCrossfades(["A": 960])
        let clips: [ClipID] = ["A", "X", "B", "C"]
        let out = Fades(fadeIn: 0, fadeOut: 24_000)!
        #expect(ClipInspection.fades(.end, ms: 500, for: clips, in: session) == ["X": out, "B": out, "C": out])
        #expect(
            ClipInspection.fades(.start, ms: 99_999, for: ["A", "X"], in: session)
                == ["A": Fades(fadeIn: 47_520, fadeOut: 0)!], "A stops at its room; X has a crossfade at its start")
    }

    /// I7: whole ms to frames; the fade stops at the other fade; a huge or negative value clamps.
    @Test mutating func aTypedFadeStopsAtTheOtherFade() throws {
        func fades(_ edge: Fades.Edge, _ ms: Double, _ clips: [ClipID]) -> [ClipID: Fades]? {
            ClipInspection.fades(edge, ms: ms, for: clips, in: session)
        }
        #expect(fades(.start, 500, ["A"]) == ["A": Fades(fadeIn: 24_000, fadeOut: 0)!])
        #expect(
            fades(.end, try #require(ClipInspection.milliseconds("99999999999999999999")), ["A"]) == [
                "A": Fades(fadeIn: 0, fadeOut: 48_000)!
            ])
        #expect(fades(.start, .infinity, ["A"]) == ["A": Fades(fadeIn: 48_000, fadeOut: 0)!])
        #expect(fades(.start, -20, ["A"]) == nil, "a negative value is 0, which is no change")

        // A 0.3 s clip D on t2: Fade In 500 ms fills it, so the field then shows Mixed.
        try session.place(Clip(id: "D", file: "fa", start: 0, offset: 0, length: 14_400), on: "t2")
        let both = try #require(fades(.start, 500, ["A", "D"]))
        #expect(both == ["A": Fades(fadeIn: 24_000, fadeOut: 0)!, "D": Fades(fadeIn: 14_400, fadeOut: 0)!])
        try session.setFades(both)
        #expect(try inspect(marks(0.1, 0.2, ["t1", "t2"])).fadeIn == .mixed)

        try session.setFades(["A": Fades(fadeIn: 0, fadeOut: 28_800)!])
        let stopped = fades(.start, 600, ["A"])
        #expect(
            stopped == ["A": Fades(fadeIn: 19_200, fadeOut: 28_800)!], "not the Command-F result: \(stopped ?? [:])")
        #expect(fades(.end, 600, ["A"]) == nil, "an equal value is no change")
    }
}
