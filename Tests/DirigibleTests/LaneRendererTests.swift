import CoreGraphics
import DirigibleCore
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

    /// The rows of `column` in lane 0 that have `color`.
    static func rows(_ renderer: LaneRenderer, column: Int, lane: Int = 0, _ color: UInt32) -> [Int] {
        (lane * 100..<(lane + 1) * 100).filter { renderer.pixel(column, $0) == color }
    }

    @Test func aFullScaleColumnFillsTheLaneAndAHalfScaleColumnFillsItsDbHeight() throws {
        let renderer = LaneRenderer()
        let bins = [PeakColumn(peak: 65535, rms: 0), PeakColumn(peak: 32768, rms: 0), PeakColumn(peak: 7, rms: 0)]

        _ = renderer.draw(Self.inputs(try Self.session(), peaks: bins), x: 0, width: 4, scale: 1)

        #expect(Self.rows(renderer, column: 0, LaneColors.peak) == Array(0..<100))
        // -6.02 dB on the -60 dB to 0 dB scale: 90% of the lane.
        let half = Self.rows(renderer, column: 1, LaneColors.peak)
        #expect(half.last == 99 && abs((half.first ?? 0) - 10) <= 1, "\(half)")
        // -79 dB is under the floor.
        #expect(Self.rows(renderer, column: 2, LaneColors.peak) == [])
        #expect(renderer.pixel(2, 99) == LaneColors.clip)
    }

    /// Only lane 1 has peaks, so a span that passes the bottom of lane 1 shows in lane 2. Column 1
    /// holds an RMS over its peak, as a damaged cache file can: the span stays whole.
    @Test func theRmsSpanIsDarkAndUnderThePeak() throws {
        let renderer = LaneRenderer()
        var inputs = Self.inputs(
            try Self.session(), peaks: [PeakColumn(peak: 65535, rms: 32768), PeakColumn(peak: 32768, rms: 65535)])
        inputs.peaks["f2"] = .computing

        _ = renderer.draw(inputs, x: 0, width: 4, scale: 1)

        #expect(Self.rows(renderer, column: 0, LaneColors.peak) == Array(0..<10))
        #expect(Self.rows(renderer, column: 0, LaneColors.rms) == Array(10..<100))
        #expect(Self.rows(renderer, column: 1, LaneColors.peak) == [])
        #expect(Self.rows(renderer, column: 1, LaneColors.rms) == Array(10..<100))
        #expect((0..<2).allSatisfy { renderer.pixel($0, 100) == LaneColors.clip }, "lane 2 starts clean")
    }

    /// Clip gain plus track gain: -3 dB and -3.0206 dB move a full-scale column to -6.02 dB.
    @Test func aClipGainOfMinus6MovesTheColumnDown() throws {
        let renderer = LaneRenderer()
        let session = try Self.session(clipGain: -3, trackGain: -3.0206)

        _ = renderer.draw(Self.inputs(session, peaks: [PeakColumn(peak: 65535, rms: 0)]), x: 0, width: 4, scale: 1)

        let rows = Self.rows(renderer, column: 0, LaneColors.peak)
        #expect(rows.last == 99 && abs((rows.first ?? 0) - 10) <= 1, "\(rows)")
    }

    @Test func aMissingClipIsRed() throws {
        let renderer = LaneRenderer()

        _ = renderer.draw(Self.inputs(try Self.session(), missing: ["f1": .missing]), x: 0, width: 6, scale: 1)

        #expect((0..<4).allSatisfy { renderer.pixel($0, 50) == LaneColors.missing })
        #expect((0..<4).allSatisfy { renderer.pixel($0, 0) == LaneColors.missingOutline })
        #expect(renderer.pixel(4, 50) == LaneColors.lane, "after the clip")
        #expect(renderer.pixel(0, 150) == LaneColors.clip, "lane 2 is whole")
    }

    /// The WAV has 256 of the 1024 frames of the clip (`.short` in `missingMedia`).
    @Test func aShortClipIsRedAfterItsRealFrames() throws {
        let renderer = LaneRenderer()

        _ = renderer.draw(Self.inputs(try Self.session(), missing: ["f1": .short(256)]), x: 0, width: 6, scale: 1)

        #expect(renderer.pixel(0, 50) == LaneColors.clip)
        #expect((1..<4).allSatisfy { renderer.pixel($0, 50) == LaneColors.missing })
    }

    /// Peaks of 256 frames for a pool length of 1024 frames, with no fault: no red.
    @Test func theRedTintComesFromMissingMediaOnly() throws {
        let renderer = LaneRenderer()

        _ = renderer.draw(Self.inputs(try Self.session(), peaks: [Self.zero]), x: 0, width: 6, scale: 1)

        let red: Set<UInt32> = [LaneColors.missing, LaneColors.missingOutline]
        #expect(
            (0..<renderer.columns).allSatisfy { c in
                (0..<renderer.rows).allSatisfy { !red.contains(renderer.pixel(c, $0)) }
            })
    }

    @Test func theSelectionBandCoversOnlyTheSelectedLanes() throws {
        let plain = LaneRenderer()
        let selected = LaneRenderer()
        let session = try Self.session()
        _ = plain.draw(Self.inputs(session), x: 0, width: 6, scale: 1)

        // The band covers columns 1 to 3; the in line is on column 1 and the out line on column 4.
        let marks = Marks(inPoint: 256, outPoint: 1024, tracks: ["t2"])
        _ = selected.draw(Self.inputs(session, marks: marks), x: 0, width: 6, scale: 1)

        for column in [2, 3] {
            #expect(selected.pixel(column, 150) == LaneColors.selected(plain.pixel(column, 150)), "column \(column)")
            #expect(selected.pixel(column, 150) != plain.pixel(column, 150))
            #expect(selected.pixel(column, 50) == plain.pixel(column, 50), "lane 1 is not selected")
        }
        #expect(selected.pixel(0, 150) == plain.pixel(0, 150), "before the in point")
        #expect(selected.pixel(4, 150) == LaneColors.outPoint, "at the out point")
        #expect(selected.pixel(5, 150) == plain.pixel(5, 150), "after the out point")
    }

    /// Markers, chapters, and the in and out points draw a line across every lane.
    @Test func markerAndChapterLinesCrossAllLanes() throws {
        let renderer = LaneRenderer()
        var session = try Self.session()
        try session.setMarker(Marker(id: "m1", name: "Intro", position: 512, kind: .marker))
        try session.setMarker(Marker(id: "m2", name: "Part 2", position: 768, kind: .chapter))

        _ = renderer.draw(
            Self.inputs(session, marks: Marks(inPoint: 256, outPoint: 1280)), x: 0, width: 6, scale: 1)

        for (column, color) in [
            (2, LaneColors.marker), (3, LaneColors.chapter), (1, LaneColors.inPoint), (5, LaneColors.outPoint),
        ] {
            #expect((0..<200).allSatisfy { renderer.pixel(column, $0) == color }, "column \(column)")
        }
        #expect(renderer.pixel(0, 50) == LaneColors.clip)
    }

    /// The lane color fills the gaps before, between, and after the clips, also where the last
    /// draw had a clip.
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
        let renderer = LaneRenderer()
        _ = renderer.draw(Self.inputs(try session([(0, 10)])), x: 0, width: 10, scale: 1)
        let buffer = renderer.bufferAddress

        _ = renderer.draw(Self.inputs(try session([(2, 2), (5, 2)])), x: 0, width: 10, scale: 1)

        #expect(renderer.bufferAddress == buffer, "the second draw reuses the pixels of the first")
        let colors = (0..<10).map { renderer.pixel($0, 50) }
        let (lane, clip) = (LaneColors.lane, LaneColors.clip)
        #expect(colors == [lane, lane, clip, clip, lane, clip, clip, lane, lane, lane])
    }

    /// The image that the view draws shows the pixels of the draw, row 0 at the top.
    @Test func theImageHoldsThePixelsOfTheDraw() throws {
        let renderer = LaneRenderer()
        let bins = [PeakColumn(peak: 65535, rms: 20000), PeakColumn(peak: 32768, rms: 0)]
        var session = try Self.session(length: 20 * 256)
        try session.setMarker(Marker(id: "m1", name: "Intro", position: Frames(256 * 7), kind: .marker))

        let image = try #require(
            renderer.draw(
                Self.inputs(session, peaks: bins, missing: ["f2": .short(Frames(256 * 12))]), x: 0, width: 20, scale: 1)
        )

        let (width, height) = (renderer.columns, renderer.rows)
        #expect(image.width == width && image.height == height)
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let drawn = try #require(context.data).bindMemory(to: UInt32.self, capacity: width * height)
        let wrong = (0..<height).flatMap { row in
            (0..<width).filter { drawn[row * width + $0] != renderer.pixel($0, row) }.map { ($0, row) }
        }
        #expect(wrong.count == 0, "the first pixel that differs: \(String(describing: wrong.first))")
        #expect(renderer.pixel(7, 0) == LaneColors.marker && renderer.pixel(15, 150) == LaneColors.missing)
    }

    @Test func theBufferIsReusedAcrossDraws() throws {
        let renderer = LaneRenderer()
        let inputs = Self.inputs(try Self.session())

        _ = renderer.draw(inputs, x: 0, width: 6, scale: 2)
        let first = renderer.bufferAddress
        _ = renderer.draw(inputs, x: 3, width: 6, scale: 2)

        #expect(first != nil && renderer.bufferAddress == first)
        #expect(renderer.columns == 12 && renderer.rows == 400)
    }
}
