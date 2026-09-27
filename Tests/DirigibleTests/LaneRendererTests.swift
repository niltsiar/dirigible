import CoreGraphics
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The lane pixels of decision 0017 (timeline-view criteria 9 and 23). Each test draws at 256
/// frames per point and scale 1, so pixel column c is level-0 bin c. Lanes are 100 px high.
struct LaneRendererTests {
    static let zero = PeakColumn(peak: 0, rms: 0)

    /// Peaks with the level-0 bins `bins` (256 frames each); the upper levels hold the maximum.
    static func peaks(_ bins: [PeakColumn]) -> Peaks {
        let top = PeakColumn(peak: bins.map(\.peak).max() ?? 0, rms: bins.map(\.rms).max() ?? 0)
        return Peaks(
            frames: Frames(bins.count * 256), stamp: FileStamp(size: 0, seconds: 0, nanoseconds: 0), channels: 1,
            sampleRate: 48_000, levels: [bins, [top], [top]])
    }

    /// Tracks `t1` and `t2`, each with one clip of `length` frames of its own file at 0.
    static func session(length: Int = 1024, clipGain: Double = 0, trackGain: Double = 0) throws -> Session {
        var session = Session(sampleRate: 48_000)
        for n in 1...2 {
            let file = FileID("f\(n)")
            try session.addFile(AudioFile(id: file, path: "f\(n).wav", layout: .mono, length: Frames(length)))
            try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono)
            try session.place(
                Clip(
                    id: ClipID("c\(n)"), file: file, start: 0, offset: 0, length: Frames(length),
                    gain: Gain(dB: clipGain)!), on: TrackID("t\(n)"))
            try session.setGain(Gain(dB: trackGain)!, track: TrackID("t\(n)"))
        }
        return session
    }

    static func inputs(
        _ session: Session, peaks: [PeakColumn] = [], missing: [FileID: MediaFault] = [:], marks: Marks = Marks()
    ) -> LaneInputs {
        LaneInputs(
            session: session, peaks: ["f1": .ready(Self.peaks(peaks)), "f2": .ready(Self.peaks(peaks))],
            missingMedia: missing, marks: marks, scale: TimelineScale(framesPerPoint: 256), laneHeight: 100)
    }

    /// The pixels of a draw of the document points 0 ..< `width` of all lanes at `scale`.
    static func render(_ inputs: LaneInputs, width: Double, scale: Double = 1) throws -> OwnedPixels {
        let pixels = OwnedPixels(try #require(laneWindow(inputs, width: width, scale: scale)))
        pixels.draw { LaneRenderer().draw(inputs, .light, into: $0) }
        return pixels
    }

    /// The rows of `column` in lane 0 that have `color`.
    static func rows(_ pixels: OwnedPixels, column: Int, lane: Int = 0, _ color: UInt32) -> [Int] {
        (lane * 100..<(lane + 1) * 100).filter { pixels.pixel(column, $0) == color }
    }

    @Test func aFullScaleColumnFillsTheLaneAndAHalfScaleColumnFillsItsDbHeight() throws {
        let bins = [PeakColumn(peak: 65535, rms: 0), PeakColumn(peak: 32768, rms: 0), PeakColumn(peak: 7, rms: 0)]

        let pixels = try Self.render(Self.inputs(try Self.session(), peaks: bins), width: 4)

        #expect(Self.rows(pixels, column: 0, LanePalette.light.peak) == Array(0..<100))
        // -6.02 dB on the -60 dB to 0 dB scale: 90% of the lane.
        let half = Self.rows(pixels, column: 1, LanePalette.light.peak)
        #expect(half.last == 99 && abs((half.first ?? 0) - 10) <= 1, "\(half)")
        // -79 dB is under the floor.
        #expect(Self.rows(pixels, column: 2, LanePalette.light.peak) == [])
        #expect(pixels.pixel(2, 99) == LanePalette.light.clip)
    }

    /// Only lane 1 has peaks, so a span that passes the bottom of lane 1 shows in lane 2. Column 1
    /// holds an RMS over its peak, as a damaged cache file can: the span stays whole.
    @Test func theRmsSpanIsDarkAndUnderThePeak() throws {
        var inputs = Self.inputs(
            try Self.session(), peaks: [PeakColumn(peak: 65535, rms: 32768), PeakColumn(peak: 32768, rms: 65535)])
        inputs.peaks["f2"] = .computing

        let pixels = try Self.render(inputs, width: 4)

        #expect(Self.rows(pixels, column: 0, LanePalette.light.peak) == Array(0..<10))
        #expect(Self.rows(pixels, column: 0, LanePalette.light.rms) == Array(10..<100))
        #expect(Self.rows(pixels, column: 1, LanePalette.light.peak) == [])
        #expect(Self.rows(pixels, column: 1, LanePalette.light.rms) == Array(10..<100))
        #expect((0..<2).allSatisfy { pixels.pixel($0, 100) == LanePalette.light.clip }, "lane 2 starts clean")
    }

    /// Clip gain plus track gain: -3 dB and -3.0206 dB move a full-scale column to -6.02 dB.
    @Test func aClipGainOfMinus6MovesTheColumnDown() throws {
        let session = try Self.session(clipGain: -3, trackGain: -3.0206)

        let pixels = try Self.render(Self.inputs(session, peaks: [PeakColumn(peak: 65535, rms: 0)]), width: 4)

        let rows = Self.rows(pixels, column: 0, LanePalette.light.peak)
        #expect(rows.last == 99 && abs((rows.first ?? 0) - 10) <= 1, "\(rows)")
    }

    @Test func aMissingClipIsRed() throws {
        let pixels = try Self.render(Self.inputs(try Self.session(), missing: ["f1": .missing]), width: 6)

        #expect((0..<4).allSatisfy { pixels.pixel($0, 50) == LanePalette.light.missing })
        #expect((0..<4).allSatisfy { pixels.pixel($0, 0) == LanePalette.light.missingOutline })
        #expect((0..<4).allSatisfy { pixels.pixel($0, 99) == LanePalette.light.missingOutline })
        #expect(pixels.pixel(4, 50) == LanePalette.light.lane, "after the clip")
        #expect(pixels.pixel(0, 150) == LanePalette.light.clip, "lane 2 is whole")
    }

    /// The WAV has 256 of the 1024 frames of the clip (`.short` in `missingMedia`).
    @Test func aShortClipIsRedAfterItsRealFrames() throws {
        let pixels = try Self.render(Self.inputs(try Self.session(), missing: ["f1": .short(256)]), width: 6)

        #expect(pixels.pixel(0, 50) == LanePalette.light.clip)
        #expect((1..<4).allSatisfy { pixels.pixel($0, 50) == LanePalette.light.missing })
    }

    /// Peaks of 256 frames for a pool length of 1024 frames, with no fault: no red.
    @Test func theRedTintComesFromMissingMediaOnly() throws {
        let pixels = try Self.render(Self.inputs(try Self.session(), peaks: [Self.zero]), width: 6)

        let red: Set<UInt32> = [LanePalette.light.missing, LanePalette.light.missingOutline]
        #expect(
            pixels.window.pixels.rows.allSatisfy { row in pixels.row(row).allSatisfy { !red.contains($0) } })
    }

    @Test func theSelectionBandCoversOnlyTheSelectedLanes() throws {
        let session = try Self.session()
        let plain = try Self.render(Self.inputs(session), width: 6)

        // The band covers columns 1 to 3; the in line is on column 1 and the out line on column 4.
        let marks = Marks(inPoint: 256, outPoint: 1024, tracks: ["t2"])
        let selected = try Self.render(Self.inputs(session, marks: marks), width: 6)

        for column in [2, 3] {
            #expect(
                selected.pixel(column, 150) == LanePalette.light.selected(plain.pixel(column, 150)), "column \(column)")
            #expect(selected.pixel(column, 150) != plain.pixel(column, 150))
            #expect(selected.pixel(column, 50) == plain.pixel(column, 50), "lane 1 is not selected")
        }
        #expect(selected.pixel(0, 150) == plain.pixel(0, 150), "before the in point")
        #expect(selected.pixel(4, 150) == LanePalette.light.outPoint, "at the out point")
        #expect(selected.pixel(5, 150) == plain.pixel(5, 150), "after the out point")
    }

    /// Markers, chapters, and the in and out points draw a line across every lane.
    @Test func markerAndChapterLinesCrossAllLanes() throws {
        var session = try Self.session()
        try session.setMarker(Marker(id: "m1", name: "Intro", position: 512, kind: .marker))
        try session.setMarker(Marker(id: "m2", name: "Part 2", position: 768, kind: .chapter))

        let pixels = try Self.render(Self.inputs(session, marks: Marks(inPoint: 256, outPoint: 1280)), width: 6)

        for (column, color) in [
            (2, LanePalette.light.marker), (3, LanePalette.light.chapter), (1, LanePalette.light.inPoint),
            (5, LanePalette.light.outPoint),
        ] {
            #expect((0..<200).allSatisfy { pixels.pixel(column, $0) == color }, "column \(column)")
        }
        #expect(pixels.pixel(0, 50) == LanePalette.light.clip)
    }

    /// The lane color fills the gaps before, between, and after the clips, also where the last
    /// draw into the same pixels had a clip.
    @Test func theGapsBetweenClipsHaveTheLaneColor() throws {
        func session(_ clips: [(start: Int, length: Int)]) throws -> Session {
            var session = Session(sampleRate: 48_000)
            try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 2560))
            try session.addTrack("t1", name: "T1", layout: .mono)
            for (n, clip) in clips.enumerated() {
                try session.place(
                    Clip(
                        id: ClipID("c\(n)"), file: "f1", start: Frames(clip.start * 256), offset: 0,
                        length: Frames(clip.length * 256)), on: "t1")
            }
            return session
        }
        let pixels = try Self.render(Self.inputs(try session([(0, 10)])), width: 10)
        let next = Self.inputs(try session([(2, 2), (5, 2)]))

        pixels.draw { LaneRenderer().draw(next, .light, into: $0) }

        let colors = (0..<10).map { pixels.pixel($0, 50) }
        let (lane, clip) = (LanePalette.light.lane, LanePalette.light.clip)
        #expect(colors == [lane, lane, clip, clip, lane, clip, clip, lane, lane, lane])
    }

    /// Each column draws one waveform: the one of the clip that holds the first frame of the
    /// column. At fit zoom, 2,000 clips per lane drew each column about 1.7 times (mouse-edits
    /// Phase 4). A (silent f1) is 0 ..< 384, B (full-scale f2 from its frame 0) is 384 ..< 900:
    /// A holds column 1 (frames 256 ..< 512), and B holds columns 2 and 3.
    @Test func aColumnDrawsTheWaveformOfTheClipThatHoldsItsFirstFrame() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 1024))
        try session.addFile(AudioFile(id: "f2", path: "f2.wav", layout: .mono, length: 1024))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.place(Clip(id: "a", file: "f1", start: 0, offset: 0, length: 384), on: "t1")
        try session.place(Clip(id: "b", file: "f2", start: 384, offset: 0, length: 516), on: "t1")
        let full = PeakColumn(peak: 65535, rms: 0)
        let inputs = LaneInputs(
            session: session,
            peaks: [
                "f1": .ready(Self.peaks([Self.zero, Self.zero])),
                "f2": .ready(Self.peaks(Array(repeating: full, count: 4))),
            ],
            missingMedia: [:], marks: Marks(), scale: TimelineScale(framesPerPoint: 256), laneHeight: 100)

        let pixels = try Self.render(inputs, width: 5)

        #expect(Self.rows(pixels, column: 1, LanePalette.light.peak) == [], "A holds column 1")
        #expect(Self.rows(pixels, column: 2, LanePalette.light.peak) == Array(0..<100), "B holds column 2")
        #expect(Self.rows(pixels, column: 3, LanePalette.light.peak) == Array(0..<100), "B holds column 3")
        #expect(Self.rows(pixels, column: 4, LanePalette.light.peak) == [], "after B")
    }

    /// Mouse-edits code gate 1 item 2: a draw of lane 2 alone (a drag event on one lane) has the
    /// rows of lane 2 of a draw of all lanes: the waveform, the band of the selected t2, and the
    /// in line.
    @Test func aDrawOfOneLaneHasTheRowsOfThatLane() throws {
        let bins = [PeakColumn(peak: 65535, rms: 32768), PeakColumn(peak: 32768, rms: 0), Self.zero]
        let inputs = Self.inputs(
            try Self.session(), peaks: bins, marks: Marks(inPoint: 256, outPoint: 768, tracks: ["t2"]))
        let all = try Self.render(inputs, width: 6)
        let one = OwnedPixels(all.window)

        one.draw(PixelRect(columns: 0..<6, rows: 100..<200)) { LaneRenderer().draw(inputs, .light, into: $0) }

        #expect((100..<200).allSatisfy { one.row($0) == all.row($0) }, "the rows of lane 2")
        #expect(one.pixel(2, 150) == LanePalette.light.selected(LanePalette.light.clip), "the band")
    }

    /// Plan gate 1 item 1: a draw writes every pixel of its rect and no pixel outside it. The rect
    /// is columns 3 ..< 9 of lane 2, in pixels that start as a sentinel. Clip c2 covers it, the
    /// band of the selected t1 and t2 passes it on both sides (columns 2 ..< 11), and the lines of
    /// a marker (column 5) and of the in and out points (columns 2 and 11) cross every lane. A
    /// second draw of the same rect over the first gives the same pixels: the band halves each
    /// pixel once.
    @Test func aDrawWritesOnlyInsideItsRect() throws {
        var session = try Self.session(length: 4096)
        try session.setMarker(Marker(id: "m1", name: "M", position: Frames(256 * 5), kind: .marker))
        let loud = PeakColumn(peak: 65535, rms: 32768)
        let inputs = Self.inputs(
            session, peaks: Array(repeating: loud, count: 16),
            marks: Marks(inPoint: Frames(256 * 2), outPoint: Frames(256 * 11), tracks: ["t1", "t2"]))
        let sentinel: UInt32 = 0xFF12_3456
        let pixels = OwnedPixels(try #require(laneWindow(inputs, width: 12)), fill: sentinel)
        let rect = PixelRect(columns: 3..<9, rows: 100..<200)

        pixels.draw(rect) { LaneRenderer().draw(inputs, .light, into: $0) }

        let outside = pixels.window.pixels.rows.flatMap { row in
            pixels.window.pixels.columns.filter { !(rect.rows.contains(row) && rect.columns.contains($0)) }
                .map { pixels.pixel($0, row) }
        }
        #expect(outside.allSatisfy { $0 == sentinel }, "\(Set(outside).map { String($0, radix: 16) })")
        let inside = rect.rows.flatMap { row in rect.columns.map { pixels.pixel($0, row) } }
        #expect(!inside.contains(sentinel), "every pixel of the rect")
        #expect(pixels.pixel(5, 150) == LanePalette.light.marker, "the marker line")
        #expect(pixels.pixel(6, 105) == LanePalette.light.selected(LanePalette.light.peak), "the band")
        pixels.draw(rect) { LaneRenderer().draw(inputs, .light, into: $0) }
        #expect(rect.rows.flatMap { row in rect.columns.map { pixels.pixel($0, row) } } == inside)
    }

    /// Plan gate 1 item 1 and the fractional-origin seam of the timeline-scroll run: at scale 2 and
    /// an origin of 2666 px (1333 pt), a draw of columns 0 ..< k and one of k ..< n (k odd: the
    /// second draw starts at a half point) give the pixels of one draw of 0 ..< n. The pixels start
    /// as a garbage color, and none of it shows. The zoom is not a power of two, so the clip edges,
    /// the band, and the lines fall at fractions of a pixel.
    @Test func twoPartialDrawsEqualOneFullDraw() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 2_000_000))
        for n in 1...3 { try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono) }
        var random = SplitMix(seed: 5)
        for n in 0..<120 {
            let start = 1_700_000 + Int(random.next() % 400_000)
            try session.place(
                Clip(
                    id: ClipID("c\(n)"), file: "f1", start: Frames(start), offset: Frames(Int(random.next() % 1000)),
                    length: Frames(300 + Int(random.next() % 20_000))), on: TrackID("t\(n % 3 + 1)"))
        }
        try session.setMarker(Marker(id: "m1", name: "M", position: 1_781_234, kind: .marker))
        let inputs = LaneInputs(
            session: session, peaks: ["f1": .ready(randomPeaks(frames: 2_000_000))],
            missingMedia: ["f1": .short(12_345)],
            marks: Marks(inPoint: 1_780_001, outPoint: 1_830_777, tracks: ["t2"]),
            scale: TimelineScale(framesPerPoint: 1333.37), laneHeight: 100)
        let window = try #require(laneWindow(inputs, x: 1333, width: 100, scale: 2))
        #expect(window.pixels.columns == 2666..<2866)
        let one = OwnedPixels(window, fill: 0xFFAB_CDEF)
        one.draw { LaneRenderer().draw(inputs, .light, into: $0) }
        let (k, rows) = (2666 + 77, window.pixels.rows)

        let two = OwnedPixels(window, fill: 0xFFAB_CDEF)
        two.draw(PixelRect(columns: 2666..<k, rows: rows)) { LaneRenderer().draw(inputs, .light, into: $0) }
        two.draw(PixelRect(columns: k..<2866, rows: rows)) { LaneRenderer().draw(inputs, .light, into: $0) }

        let wrong = rows.flatMap { row in window.pixels.columns.filter { one.pixel($0, row) != two.pixel($0, row) } }
        #expect(wrong.isEmpty, "\(wrong.count) pixels differ, the first at column \(wrong.first ?? 0)")
        #expect(!rows.contains { one.row($0).contains(0xFFAB_CDEF) }, "the garbage color shows")
    }
}
