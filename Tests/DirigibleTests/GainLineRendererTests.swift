import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Criteria L1 to L3 and L5 of run 11b-1: the gain line, the fade handles, the clip label, and
/// the readout text. The lanes of `LaneRendererTests`: 256 frames per point, 100 pt lanes, here at
/// scale 2, so a lane has 200 rows and a point has 2 columns.
struct GainLineRendererTests {
    /// A DC signal at 0 dBFS: every level-0 bin at full scale.
    static func full(_ frames: Int) -> [PeakColumn] {
        Array(repeating: PeakColumn(peak16: 65535, rms16: 65535), count: frames / 256)
    }

    /// The pixels of a draw of 220 pt at scale 2 of t1 and t2, each with a clip of `points` pt of
    /// 0 dBFS from 0.
    static func render(
        points: Double, clipGain: Double = 0, trackGain: Double = 0, fades: Fades = .zero,
        change: (inout LaneInputs) throws -> Void = { _ in }
    ) throws -> OwnedPixels {
        let frames = Int(points * 256)
        var session = try LaneRendererTests.session(length: frames, clipGain: clipGain, trackGain: trackGain)
        try session.setFades(["c1": fades])
        var inputs = LaneRendererTests.inputs(session, peaks: full(frames))
        try change(&inputs)
        return try LaneRendererTests.render(inputs, width: 220, scale: 2)
    }

    static let label = LanePalette.light.label

    /// The columns of lane 0 that have the label color in `row`.
    static func labelColumns(_ pixels: OwnedPixels, row: Int) -> [Int] {
        pixels.window.pixels.columns.filter { pixels.pixel($0, row) == label }
    }

    /// True when no pixel of lane 0 has the label color.
    static func noLabel(_ pixels: OwnedPixels) -> Bool {
        (0..<200).allSatisfy { labelColumns(pixels, row: $0).isEmpty }
    }

    @Test func theGainLineOnlyInBoxesOf40Points() throws {
        // -6 dB on a 200-row lane: height 180, so the line is on row 199 - 180 + 1 = 20.
        let quiet = try Self.render(points: 100, clipGain: -6)
        #expect(Self.labelColumns(quiet, row: 20) == Array(0..<200), "the line from the start to the end")
        #expect(quiet.pixel(100, 21) == LanePalette.light.rms, "the waveform top is under the line")

        let dashes = (0..<200).filter { ($0 / 3) % 2 == 0 }
        let loud = try Self.render(points: 100, clipGain: 4)
        #expect(Self.labelColumns(loud, row: 0) == dashes, "over 0 dB: dashed on the top row")
        let track = try Self.render(points: 100, trackGain: 3)
        #expect(Self.labelColumns(track, row: 0) == dashes, "the track gain adds")
        let zero = try Self.render(points: 100)
        #expect(Self.labelColumns(zero, row: 0) == Array(0..<200), "0 dB: solid on the top row")

        #expect(Self.noLabel(try Self.render(points: 39, clipGain: -6)), "a box of 39 pt")
        let faded = try Self.render(points: 100, clipGain: -6, fades: Fades(fadeIn: 2_560, fadeOut: 0)!)
        // The fade line of decision 0035 has the columns of the fade-in (0 to 18); the gain line the rest.
        let line = Set(Self.labelColumns(faded, row: 20))
        #expect(Set(19..<200).isSubset(of: line) && !line.contains(5), "the line starts at the fade-in end")
    }

    @Test func theHandlesDrawAtTheFadeEnds() throws {
        // At -20 dB the line is on row 67, under the handles (rows 2 to 13).
        let plain = try Self.render(points: 100, clipGain: -20)
        #expect(Self.labelColumns(plain, row: 2) == Array(2..<14) + Array(186..<198))
        #expect(Self.labelColumns(plain, row: 13) == Array(2..<14) + Array(186..<198))
        #expect(Self.labelColumns(plain, row: 1).isEmpty && Self.labelColumns(plain, row: 14).isEmpty)
        let faded = try Self.render(points: 100, clipGain: -20, fades: Fades(fadeIn: 2_560, fadeOut: 0)!)
        #expect(Array(Self.labelColumns(faded, row: 5).prefix(12)) == Array(14..<26), "at the fade-in end")
        #expect(Self.noLabel(try Self.render(points: 39, clipGain: -20)), "a box of 39 pt")

        // The line and the handles come from the clip fields only, not from the peaks or the media.
        let states: [(inout LaneInputs) -> Void] = [
            { $0.peaks["f1"] = .unavailable }, { $0.peaks["f1"] = .computing },
            { $0.missingMedia["f1"] = .missing },
        ]
        for state in states {
            let pixels = try Self.render(points: 100, clipGain: -20, change: state)
            #expect(Self.labelColumns(pixels, row: 5) == Array(2..<14) + Array(186..<198))
        }
    }

    /// c3 starts at the end of c1 on t1, with no fade: no handle at the join.
    @Test func noHandleAtAButtJoin() throws {
        let pixels = try Self.render(points: 100, clipGain: -20) { inputs in
            try inputs.session.place(Clip(id: "c3", file: "f1", start: 25_600, offset: 0, length: 25_600), on: "t1")
        }
        #expect(Self.labelColumns(pixels, row: 5) == Array(2..<14) + Array(386..<398))
    }

    @Test func theLabelShowsAGainThatIsNotZero() {
        let (en, es) = (Locale(identifier: "en"), Locale(identifier: "es"))
        #expect(TimelineDocumentView.labelText("take1-1", gain: Gain(dB: -6)!, locale: en) == "take1-1  -6.0 dB")
        #expect(TimelineDocumentView.labelText("take1-1", gain: Gain(dB: -6)!, locale: es) == "take1-1  -6,0 dB")
        #expect(TimelineDocumentView.labelText("take1-1", gain: Gain(dB: 4)!, locale: en) == "take1-1  +4.0 dB")
        #expect(TimelineDocumentView.labelText("take1-1", gain: .zero, locale: en) == "take1-1")
    }

    @Test func theReadoutTextInEachLanguage() throws {
        let (en, es) = (try stringsTable("en"), try stringsTable("es"))
        func text(_ readout: GestureReadout, _ table: [String: String], _ locale: String) -> String {
            ReadoutLayer.text(readout, rate: 48_000, locale: Locale(identifier: locale)) { table[$0.rawValue] ?? "" }
        }

        #expect(text(.gain(Gain(dB: -6)!, from: .zero), en, "en") == "Gain -6.0 dB (-6.0)")
        #expect(text(.gain(Gain(dB: -6)!, from: .zero), es, "es") == "Ganancia -6,0 dB (-6,0)")
        // C24b: the change since the mouse-down.
        #expect(text(.gain(Gain(dB: 4)!, from: Gain(dB: 6)!), en, "en") == "Gain +4.0 dB (-2.0)")
        #expect(text(.gain(Gain(dB: 4)!, from: Gain(dB: 6)!), es, "es") == "Ganancia +4,0 dB (-2,0)")
        #expect(text(.gain(Gain(dB: 6)!, from: Gain(dB: 6)!), en, "en") == "Gain +6.0 dB (0.0)")
        #expect(text(.fade(.start, 22_080), en, "en") == "Fade In 460 ms")
        #expect(text(.fade(.start, 22_080), es, "es") == "Entrada 460 ms")
        #expect(text(.fade(.end, 24), en, "en") == "Fade Out 1 ms", "rounded to the nearest ms")
        #expect(text(.fade(.end, 24), es, "es") == "Salida 1 ms")
        #expect(text(.crossfade(960), en, "en") == "Crossfade 20 ms")
        #expect(text(.crossfade(960), es, "es") == "Fundido cruzado 20 ms")
    }
}
