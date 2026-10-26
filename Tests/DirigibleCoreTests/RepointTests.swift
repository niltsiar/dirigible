import Foundation
import Testing

@testable import DirigibleCore

/// A clip moves onto the file that a render made from its run (decision 0054). At 48 kHz the handle
/// on each side of a clip is 10 s, 480 000 frames.
struct RepointTests {
    /// A 48 kHz session with the stereo track "t" and the stereo file "f" of `length` frames, with
    /// the clips (id, offset in "f", length) one after the other on "t".
    func session(length: Frames = 10_000_000, at first: Frames = .zero, clips: [(ClipID, Frames, Frames)]) throws
        -> Session
    {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t", name: "Host", layout: .stereo)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .stereo, length: length))
        var start = first
        for (id, offset, clipLength) in clips {
            try session.place(Clip(id: id, file: "f", start: start, offset: offset, length: clipLength), on: "t")
            start = start + clipLength
        }
        return session
    }

    /// One `RenderedRun` for each run of `clips`, with the stems "<file> NR", "<file> NR 2", and so on.
    func rendered(_ session: Session, _ clips: [ClipID]) throws -> [RenderedRun] {
        try session.clipRuns(of: clips).enumerated().map { index, run in
            RenderedRun(run: run, stem: "\(run.file) NR\(index == 0 ? "" : " \(index + 1)")")
        }
    }

    /// C1. Each clip of a run moves to the new file at (old offset - run start), and keeps its ID,
    /// start, length, gain, and fades. The new file has the layout of the source and the run length.
    /// The source file stays. The returned list has each moved clip with its new file, in run order.
    @Test func clipsMoveToTheNewFile() throws {
        var session = try session(clips: [("A", 1_000_000, 100_000), ("B", 1_160_000, 50_000)])
        try session.addFile(AudioFile(id: "g", path: "g.wav", layout: .stereo, length: 5_000_000))
        try session.place(Clip(id: "C", file: "g", start: 200_000, offset: 2_000_000, length: 80_000), on: "t")
        try session.place(Clip(id: "D", file: "g", start: 300_000, offset: 2_080_000, length: 60_000), on: "t")
        try session.setGain(#require(Gain(dB: -3)), clip: "A")
        try session.setFades(["B": #require(Fades(fadeIn: 480, fadeOut: 960))])
        let before = ["A", "B", "C", "D"].compactMap { session.clip($0)?.clip }
        let runs = try rendered(session, ["D", "C", "B", "A"])

        let moved = try session.repoint(runs)

        #expect(runs.map(\.stem) == ["f NR", "g NR 2"], "the fixture has one run for each file")
        #expect(
            moved
                == [
                    RenderedClip(clip: "A", file: "f NR"), RenderedClip(clip: "B", file: "f NR"),
                    RenderedClip(clip: "C", file: "g NR 2"), RenderedClip(clip: "D", file: "g NR 2"),
                ])
        #expect(session.files["f NR"] == AudioFile(id: "f NR", path: "f NR.wav", layout: .stereo, length: 1_170_000))
        #expect(
            session.files["g NR 2"] == AudioFile(id: "g NR 2", path: "g NR 2.wav", layout: .stereo, length: 1_100_000))
        #expect(session.files["f"] != nil && session.files["g"] != nil, "the source files stay")
        let offsets = [480_000, 640_000, 480_000, 560_000]
        for (index, old) in before.enumerated() {
            let found = try #require(session.clip(old.id)?.clip)
            var expected = old
            expected.file = moved[index].file
            expected.offset = Frames(offsets[index])
            #expect(found == expected, "\(old.id)")
        }
    }

    /// C1. The new file names the capture of its source file, so the capture stays after the source
    /// file goes.
    @Test func newFileKeepsCapture() throws {
        var session = Session(sampleRate: 48_000)
        try session.addCapture(
            Capture(
                id: "k1", deviceUID: "usb-1", deviceName: "USB Mic", hostTimeNanos: 1, sampleTime: 0,
                nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0))
        try session.addTrack("t", name: "Host", layout: .stereo)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .stereo, length: 2_000_000, capture: "k1"))
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 100_000, length: 100_000), on: "t")

        _ = try session.repoint(rendered(session, ["A"]))

        #expect(session.files["f NR"]?.capture == "k1")
        try session.removeFile("f")
        #expect(throws: SessionError.captureInUse("k1")) { try session.removeCapture("k1") }
    }

    /// C1. A moved clip trims out to the edges of its new file, which is the handle for a one-clip
    /// run: one frame more is refused.
    @Test func trimExtendsIntoHandle() throws {
        var session = try session(at: 1_000_000, clips: [("A", 1_000_000, 100_000)])
        _ = try session.repoint(rendered(session, ["A"]))

        try session.trim("A", to: 520_000..<1_580_000)
        let trimmed = try #require(session.clip("A")?.clip)
        #expect(trimmed.offset == 0 && trimmed.length.count == 1_060_000)
        #expect(throws: SessionError.clipOutsideFile("A")) { try session.trim("A", to: 519_999..<1_100_000) }
        #expect(throws: SessionError.clipOutsideFile("A")) { try session.trim("A", to: 1_000_000..<1_580_001) }
    }

    /// C1. A crossfade between two moved clips stays, also when its half is longer than the 10 s
    /// handle: the run covers the half, so the new file holds the media that the crossfade reads.
    @Test func crossfadesStayInTheHandle() throws {
        var session = try session(clips: [("A", 1_000_000, 700_000), ("B", 4_100_000, 800_000)])
        try session.setCrossfades(["A": 1_200_000])
        let runs = try rendered(session, ["A", "B"])

        _ = try session.repoint(runs)

        #expect(session.files["f NR"]?.length == 1_780_000, "520 000 to 2 300 000 of f")
        #expect(session.files["f NR 2"]?.length == 1_880_000, "3 500 000 to 5 380 000 of f")
        #expect(session.clip("A")?.clip.crossfades == Crossfades(start: 0, end: 1_200_000))
        #expect(session.clip("B")?.clip.crossfades == Crossfades(start: 1_200_000, end: 0))
        #expect(session.clip("A")?.clip.offset == 480_000 && session.clip("B")?.clip.offset == 600_000)
    }

    /// C1. A moved clip plays the gain of the source clip at each source frame: the envelope moves by
    /// the run start, a point outside the run becomes a point at the run edge with the source gain
    /// there (decision 0060), and an empty envelope stays empty.
    @Test func repointKeepsTheEnvelopeGain() throws {
        var session = try session(clips: [("A", 1_000_000, 100_000)])
        let points = [(100_000, -10.0), (700_000, -4), (1_200_000, 6), (3_000_000, -20)]
        let source = Clip(
            id: "E", file: "f", start: 100_000, offset: 1_000_000, length: 100_000, envelope: envelope(points))
        try session.place(source, on: "t")
        let before = try #require(session.clip("E")?.clip)

        _ = try session.repoint(rendered(session, ["A", "E"]))

        // The run is 520_000..<1_580_000 of "f": the points at 100_000 and 3_000_000 fall outside.
        let frames = [0, 180_000, 680_000, 1_060_000]
        let found = try #require(session.clip("E")?.clip)
        #expect(found.envelope.points.map(\.frame.count) == frames)
        for frame in frames + [1, 90_000, 179_999, 400_000, 679_999, 900_000, 1_059_999] {
            let expected = before.envelope.gain(at: Frames(frame + 520_000))
            #expect(abs(found.envelope.gain(at: Frames(frame)) - expected) < 1e-9, "at \(frame)")
        }
        #expect(try #require(session.clip("A")?.clip).envelope.isEmpty, "an empty envelope stays empty")
    }

    /// C1. Two clips that play on in one file stay a seamless join in the new file, and Heal joins
    /// them there exactly when it joined the source clips: with equal envelope gain at the join, not
    /// with different gain.
    @Test(arguments: [(-6.0, true), (-12.0, false)])
    func seamlessJoinStaysSeamless(rightGain: Double, heals: Bool) throws {
        var session = try session(clips: [])
        let envelopes = [envelope([(1_000_000, -6)]), envelope([(1_100_000, rightGain)])]
        try session.place(
            Clip(id: "A", file: "f", start: 0, offset: 1_000_000, length: 100_000, envelope: envelopes[0]), on: "t")
        try session.place(
            Clip(id: "B", file: "f", start: 100_000, offset: 1_100_000, length: 100_000, envelope: envelopes[1]),
            on: "t")
        #expect(session.tracks[0].clips.canHeal(after: 0) == heals, "the source clips")

        _ = try session.repoint(rendered(session, ["A", "B"]))

        #expect(session.tracks[0].clips.join(after: 0) == .seamless)
        #expect(session.tracks[0].clips.canHeal(after: 0) == heals)
    }

    /// C1. A session with an envelope point and a crossfade at a seamless join keeps its version
    /// through the move: 10, and 11 with a role on the track. The saved file reads back equal.
    @Test(arguments: [(false, 10), (true, 11)])
    func versionUnchanged(role: Bool, version: Int) throws {
        var session = try session(clips: [])
        try session.place(Clip(id: "A", file: "f", start: 0, offset: 1_000_000, length: 100_000), on: "t")
        try session.place(
            Clip(
                id: "B", file: "f", start: 100_000, offset: 1_100_000, length: 100_000,
                envelope: envelope([(1_150_000, -6)])),
            on: "t")
        if role { try session.setRole(.dialogue, tracks: ["t"]) }
        try session.setCrossfades(["A": 960])
        #expect(session.fileVersion == version)

        _ = try session.repoint(rendered(session, ["A", "B"]))

        #expect(session.fileVersion == version)
        let data = try session.checkedData()
        #expect(String(decoding: data, as: UTF8.self).contains(#"version="\#(version)""#))
        #expect(try Session(xml: data, newest: 11) == session)
    }

    /// C1. A run that is not the run of its clips throws `.frameOutOfRange` and changes nothing: a
    /// shorter span, and a run that the list names twice.
    @Test func badRunRefused() throws {
        var session = try session(clips: [("A", 1_000_000, 100_000), ("B", 5_000_000, 100_000)])
        let before = session
        let runs = try rendered(session, ["A", "B"])
        let short = ClipRun(file: "f", span: 600_000..<1_580_000, clips: ["A"])

        #expect(throws: SessionError.frameOutOfRange) {
            try session.repoint([RenderedRun(run: short, stem: "x"), runs[1]])
        }
        #expect(throws: SessionError.frameOutOfRange) {
            try session.repoint([runs[0], runs[0]])
        }
        #expect(session == before)
    }

    /// C1. A stem whose ID or path is in the pool, and the same stem twice, throw `.duplicateID` and
    /// change nothing, also the clips of an earlier run.
    @Test func duplicateStemRefused() throws {
        var session = try session(clips: [("A", 1_000_000, 100_000), ("B", 5_000_000, 100_000)])
        try session.addFile(AudioFile(id: "g", path: "taken.wav", layout: .stereo, length: 1_000))
        try session.addFile(AudioFile(id: "taken id", path: "other.wav", layout: .stereo, length: 1_000))
        let before = session
        let runs = try session.clipRuns(of: ["A", "B"])
        func call(_ stems: [String]) throws(SessionError) {
            _ = try session.repoint(zip(runs, stems).map { RenderedRun(run: $0, stem: $1) })
        }

        #expect(throws: SessionError.duplicateID("taken id")) { try call(["ok", "taken id"]) }
        #expect(throws: SessionError.duplicateID("taken.wav")) { try call(["taken", "ok"]) }
        #expect(throws: SessionError.duplicateID("same")) { try call(["same", "same"]) }
        #expect(session == before)
    }

    /// C1 and C7c. A transcript that did not load throws `.transcriptNotLoaded` and changes nothing.
    @Test func transcriptUnloadedRefused() throws {
        var session = try session(clips: [("A", 1_000_000, 100_000)])
        session.transcripts[TranscriptID(1)] = Transcript(id: TranscriptID(1), name: "t1", words: nil)
        let before = session

        #expect(throws: SessionError.transcriptNotLoaded([TranscriptID(1)])) {
            try session.repoint(self.rendered(session, ["A"]))
        }
        #expect(session == before)
    }
}
