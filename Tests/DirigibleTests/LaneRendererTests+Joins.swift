import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The join at each cut between two clips (timeline clarity C7, C8). At 256 frames per point, A is
/// 0 ..< 100 pt and B is 100 ..< 200 pt on t1 and on t2, so the join is at point 100: 2 pt wide,
/// the columns 99 and 100 at scale 1. Every peak is full scale, so the waveform runs the whole
/// lane height and covers the box: only a pass after the waveform shows the join.
struct LaneRendererJoinTests {
    static let full = PeakColumn(peak16: 65535, rms16: 32768)

    /// Two tracks with A and B each. `lengths` are the frames of A and B, `gap` the frames
    /// between them.
    static func session(lengths: (Int, Int) = (25_600, 25_600), gap: Int = 0, fades: Fades? = nil) throws -> Session {
        var session = Session(sampleRate: 48_000)
        for n in 1...2 {
            try session.addFile(AudioFile(id: FileID("f\(n)"), path: "f\(n).wav", layout: .mono, length: 76_800))
            try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono)
            try session.place(
                Clip(id: ClipID("a\(n)"), file: FileID("f\(n)"), start: 0, offset: 0, length: Frames(lengths.0)),
                on: TrackID("t\(n)"))
            try session.place(
                Clip(
                    id: ClipID("b\(n)"), file: FileID("f\(n)"), start: Frames(lengths.0 + gap),
                    offset: Frames(lengths.0 + gap), length: Frames(lengths.1)), on: TrackID("t\(n)"))
        }
        if let fades { try session.setFades(["b1": fades]) }
        return session
    }

    static func inputs(_ session: Session, marks: Marks? = nil) -> LaneInputs {
        var inputs = LaneRendererTests.inputs(session, peaks: Array(repeating: full, count: 300))
        inputs.selection = marks.map { .range($0) } ?? .none
        return inputs
    }

    static func render(_ inputs: LaneInputs, _ palette: LanePalette, scale: Double, width: Double = 220) throws
        -> OwnedPixels
    {
        let pixels = OwnedPixels(try #require(laneWindow(inputs, width: width, scale: scale)))
        pixels.draw { LaneRenderer().draw(inputs, palette, into: $0) }
        return pixels
    }

    /// Whether every row of `lane` in `columns` has `color`.
    static func lane(_ lane: Int, _ columns: Range<Int>, are color: UInt32, in pixels: OwnedPixels) -> Bool {
        let rows = pixels.window.rows(of: lane..<lane + 1)
        return columns.allSatisfy { column in rows.allSatisfy { pixels.pixel(column, $0) == color } }
    }

    @Test(arguments: [LanePalette.light, LanePalette.dark(accent: 0xFFFF_2D55)], [1.0, 2.0])
    func aButtJoinDrawsTheJoinColorOnEveryTrack(palette: LanePalette, scale: Double) throws {
        let join = Int(100 * scale)
        let columns = join - Int(scale)..<join + Int(scale)

        let pixels = try Self.render(Self.inputs(try Self.session()), palette, scale: scale)

        for lane in 0..<2 {
            #expect(Self.lane(lane, columns, are: palette.join, in: pixels), "lane \(lane): 2 pt of the join color")
            // The join is 2 pt: the waveform (the RMS span at mid height) shows on each side.
            let middle = pixels.window.rows(of: lane..<lane + 1).lowerBound + pixels.window.laneRows / 2
            #expect(pixels.pixel(columns.lowerBound - 1, middle) == palette.rms)
            #expect(pixels.pixel(columns.upperBound, middle) == palette.rms)
        }
        let marks = Marks(inPoint: 12_800, outPoint: 38_400, tracks: ["t1", "t2"])
        let banded = try Self.render(Self.inputs(try Self.session(), marks: marks), palette, scale: scale)
        for lane in 0..<2 {
            #expect(Self.lane(lane, columns, are: palette.selected(palette.join), in: banded), "the band over the join")
        }
        // No join: boxes under 12 pt, a wide box next to a narrow one, and a gap of one frame. The
        // dark join is the lane color, so the check is on the columns of the cut.
        for (session, point) in [
            (try Self.session(lengths: (2816, 2816)), 11), (try Self.session(lengths: (25_600, 2816)), 100),
            (try Self.session(gap: 1), 100),
        ] {
            let plain = try Self.render(Self.inputs(session), palette, scale: scale)
            let cut = Int(Double(point) * scale) - Int(scale)..<Int(Double(point) * scale) + Int(scale)
            #expect(
                !Self.lane(0, cut, are: palette.join, in: plain), "no join at \(session.tracks[0].clips.map(\.range))")
        }
    }

    /// A trim of A moves its end, so the join goes. The dirty rect of the trim (`changedFrames`
    /// with 1 pt on each side, as the view marks it) must hold the join columns, also when B has a
    /// fade-in and so draws no new handle at the cut.
    @Test(arguments: [true, false])
    func aTrimOfTheLeftClipRedrawsTheJoin(shorter: Bool) throws {
        let fades = try #require(Fades(fadeIn: 4800, fadeOut: 0))
        let butt = try Self.session(fades: fades)
        var trimmed = butt
        try trimmed.trim("a1", to: 0..<20_480)
        let (old, new) = shorter ? (butt, trimmed) : (trimmed, butt)
        let (oldInputs, newInputs) = (Self.inputs(old), Self.inputs(new))
        let scale = 2.0
        let pixels = try Self.render(oldInputs, .light, scale: scale)
        let expected = try Self.render(newInputs, .light, scale: scale)
        #expect(Self.lane(0, 198..<202, are: LanePalette.light.join, in: shorter ? pixels : expected), "the join")

        let frames = try #require(changedFrames(from: old, to: new)).frames
        let geometry = try #require(newInputs.geometry)
        let x0 = geometry.x(of: frames.lowerBound).rounded(.down) - 1
        let x1 = geometry.x(of: frames.upperBound).rounded(.up) + 1
        let rect = PixelRect(columns: Int(x0 * scale)..<Int(x1 * scale), rows: pixels.window.pixels.rows)
        pixels.draw(rect) { LaneRenderer().draw(newInputs, .light, into: $0) }

        let differing = pixels.window.pixels.rows.filter { pixels.row($0) != expected.row($0) }
        #expect(differing.isEmpty, "\(differing.count) rows differ from a full draw of the new session")
    }

    /// A partial draw of a part of the columns gives the pixels of a full draw there: one that
    /// ends in the left half of the join (columns 198 and 199 at scale 2), and one that starts in
    /// its right half (columns 200 and 201).
    @Test func aPartialDrawThatEndsInTheLeftHalfOfAJoinDrawsIt() throws {
        let inputs = Self.inputs(try Self.session())
        let full = try Self.render(inputs, .light, scale: 2)
        #expect(Self.lane(0, 198..<202, are: LanePalette.light.join, in: full), "the join")
        let rows = full.window.pixels.rows
        let count = full.window.pixels.columns.count

        for columns in [0..<200, 200..<count] {
            let partial = OwnedPixels(full.window, fill: 0xDEAD_BEEF)
            partial.draw(PixelRect(columns: columns, rows: rows)) { LaneRenderer().draw(inputs, .light, into: $0) }
            let differing = rows.filter { Array(partial.row($0)[columns]) != Array(full.row($0)[columns]) }
            #expect(differing.isEmpty, "\(differing.count) rows differ in \(columns)")
        }
    }
}
