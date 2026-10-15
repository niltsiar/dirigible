import Foundation
import Testing

@testable import DirigibleCore

/// The runs of clips of one file and the record of a file made from a run (decision 0056). At
/// 48 kHz the handle on each side of a clip is 10 s, 480 000 frames.
struct DerivedFileTests {
    /// A 48 kHz session with the mono track "t" and the file "f" of `length` frames, with the clips
    /// (id, offset in "f", length) one after the other on "t".
    func session(length: Frames = 10_000_000, clips: [(ClipID, Frames, Frames)]) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t", name: "T", layout: .mono)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: length))
        var start = Frames.zero
        for (id, offset, clipLength) in clips {
            try session.place(Clip(id: id, file: "f", start: start, offset: offset, length: clipLength), on: "t")
            start = start + clipLength
        }
        return session
    }

    /// C9. Clip spans 960 000 frames apart have written spans that touch: one run, in offset order.
    @Test func touchingSpansMerge() throws {
        let session = try session(clips: [("A", 1_000_000, 100_000), ("B", 2_060_000, 100_000)])

        let runs = try session.clipRuns(of: ["B", "A"], sampleRate: 48_000)

        #expect(runs == [ClipRun(file: "f", span: 520_000..<2_640_000, clips: ["A", "B"])])
    }

    /// C9. One more frame between the clip spans gives two runs.
    @Test func aGapOfOneMoreFrameGivesTwoRuns() throws {
        let session = try session(clips: [("A", 1_000_000, 100_000), ("B", 2_060_001, 100_000)])

        let runs = try session.clipRuns(of: ["A", "B"], sampleRate: 48_000)

        #expect(
            runs == [
                ClipRun(file: "f", span: 520_000..<1_580_000, clips: ["A"]),
                ClipRun(file: "f", span: 1_580_001..<2_640_001, clips: ["B"]),
            ])
    }

    /// C9. The handles stop at the start and the end of the file.
    @Test func theSpanStopsAtTheFileEnd() throws {
        let session = try session(length: 1_000_000, clips: [("A", 100_000, 800_000)])

        let runs = try session.clipRuns(of: ["A"], sampleRate: 48_000)

        #expect(runs == [ClipRun(file: "f", span: 0..<1_000_000, clips: ["A"])])
    }

    /// A crossfade longer than two handles widens the span by half its length.
    @Test func aLongCrossfadeWidensTheSpan() throws {
        var session = Session(sampleRate: 100)
        try session.addTrack("t", name: "T", layout: .mono)
        for id in ["fa", "fb"] as [FileID] {
            try session.addFile(AudioFile(id: id, path: "\(id).wav", layout: .mono, length: 100_000))
        }
        try session.place(Clip(id: "A", file: "fa", start: 0, offset: 10_000, length: 20_000), on: "t")
        try session.place(Clip(id: "B", file: "fb", start: 20_000, offset: 10_000, length: 20_000), on: "t")
        try session.setCrossfades(["A": 4_000])

        let runs = try session.clipRuns(of: ["A"], sampleRate: 100)

        #expect(runs == [ClipRun(file: "fa", span: 9_000..<32_000, clips: ["A"])])
    }

    /// C9. An unknown clip ID throws and names the clip.
    @Test func anUnknownClipIsRefused() throws {
        let session = try session(clips: [("A", 1_000_000, 100_000)])

        #expect(throws: SessionError.unknownClip("X")) { try session.clipRuns(of: ["A", "X"], sampleRate: 48_000) }
    }

    /// A clip whose file record is missing throws and names the file, not the clip.
    @Test func aMissingFileRecordIsNamed() throws {
        var session = Session(sampleRate: 48_000)
        session.tracks = try self.session(clips: [("A", 1_000_000, 100_000)]).tracks

        #expect(throws: SessionError.unknownFile("f")) { try session.clipRuns(of: ["A"], sampleRate: 48_000) }
    }

    /// C10. The new record has the stem, the span length, the layout, and the capture of the source.
    @Test func aDerivedFileKeepsTheCapture() throws {
        var session = Session(sampleRate: 48_000)
        try session.addCapture(
            Capture(
                id: "k1", deviceUID: "usb-1", deviceName: "USB Mic", hostTimeNanos: 1, sampleTime: 0,
                nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0))
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .stereo, length: 1_000_000, capture: "k1"))

        let id = try session.addDerivedFile(
            from: ClipRun(file: "f", span: 100_000..<300_000, clips: []), stem: "f L", layout: .mono)

        #expect(id == "f L")
        #expect(
            session.files["f L"]
                == AudioFile(id: "f L", path: "f L.wav", layout: .mono, length: 200_000, capture: "k1"))
    }

    /// C10. A taken file ID, also with an equal record, and an unknown source file throw and change
    /// nothing.
    @Test func aTakenIDChangesNothing() throws {
        var session = try session(clips: [])
        let run = ClipRun(file: "f", span: 100_000..<300_000, clips: [])
        try session.addFile(AudioFile(id: "f NR", path: "f NR.wav", layout: .mono, length: 200_000))
        let before = session

        #expect(throws: SessionError.duplicateID("f NR")) {
            try session.addDerivedFile(from: run, stem: "f NR", layout: .mono)
        }
        #expect(throws: SessionError.unknownFile("g")) {
            try session.addDerivedFile(from: ClipRun(file: "g", span: run.span, clips: []), stem: "g NR", layout: .mono)
        }
        #expect(session == before)
    }

    /// A path that another record has throws and changes nothing, also in another case: one WAV has
    /// one file record.
    @Test func aTakenPathIsRefused() throws {
        var session = try session(clips: [])
        try session.addFile(AudioFile(id: "g", path: "f NR.wav", layout: .mono, length: 200_000))
        let run = ClipRun(file: "f", span: 100_000..<300_000, clips: [])
        let before = session

        for stem in ["f NR", "f nr"] {
            #expect(throws: SessionError.duplicateID("\(stem).wav")) {
                try session.addDerivedFile(from: run, stem: stem, layout: .mono)
            }
        }
        #expect(session == before)
    }

    /// An empty span and a span past the end of the source throw and change nothing.
    @Test func aSpanOutsideTheFileIsRefused() throws {
        var session = try session(length: 1_000_000, clips: [])
        let before = session

        for span: Range<Frames> in [500_000..<500_000, 900_000..<1_000_001] {
            #expect(throws: SessionError.frameOutOfRange) {
                try session.addDerivedFile(from: ClipRun(file: "f", span: span, clips: []), stem: "f NR", layout: .mono)
            }
        }
        #expect(session == before)
    }

    /// C11. Each word whose midpoint is in the span goes to the new file, clamped to the span and
    /// shifted to its start, with the same transcript and number. A midpoint at the span end stays out.
    @Test func aDerivedFileKeepsTheWords() throws {
        var session = try session(length: 1_000_000, clips: [])
        session.addWords(
            [(1, 90_000..<110_000, "first"), (2, 150_000..<160_000, "inside"), (3, 190_000..<210_000, "after")],
            file: "f")
        session.addWords([(7, 120_000..<130_000, "other")], file: "f", transcript: 2)

        try session.addDerivedFile(
            from: ClipRun(file: "f", span: 100_000..<200_000, clips: []), stem: "f NR", layout: .mono)

        #expect(
            session.transcripts[TranscriptID(1)]?.words?["f NR"]?.all == [
                Anchor(number: 1, range: 0..<10_000, text: "first"),
                Anchor(number: 2, range: 50_000..<60_000, text: "inside"),
            ])
        #expect(
            session.transcripts[TranscriptID(2)]?.words?["f NR"]?.all == [
                Anchor(number: 7, range: 20_000..<30_000, text: "other")
            ])
        #expect(session.transcripts[TranscriptID(1)]?.words?["f"]?.all.count == 3, "the source keeps its words")
    }
}
