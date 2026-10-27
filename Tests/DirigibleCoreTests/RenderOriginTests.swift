import Foundation
import Testing

@testable import DirigibleCore

/// A rendered file keeps its origin through each clip edit, and Restore Original goes back to the
/// root (decision 0057). At 48 kHz the handle on each side of a clip is 10 s, 480 000 frames.
struct RenderOriginTests {
    let noise = Treatment(.noise(.standard))

    /// The stereo file "f" of 10 000 000 frames, and the clip "A" (start 0, offset 1 000 000,
    /// length 100 000, +10 dB).
    func placed() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t", name: "Host", layout: .stereo)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .stereo, length: 10_000_000))
        let clip = Clip(
            id: "A", file: "f", start: 0, offset: 1_000_000, length: 100_000, gain: try #require(Gain(dB: 10)))
        try session.place(clip, on: "t")
        return session
    }

    /// Renders the runs of `clips` into files named `stem` and `stem` 2, and so on, as `repoint`
    /// gets them from a render with the added gain `dB` for each run.
    func render(_ session: inout Session, _ clips: [ClipID] = ["A"], stem: String, dB: [Double] = [1]) throws {
        let runs = try session.clipRuns(of: clips).enumerated().map { index, run in
            RenderedRun(
                run: run, stem: index == 0 ? stem : "\(stem) \(index + 1)", treatment: noise,
                addedGain: try #require(Gain(dB: dB[index])))
        }
        _ = try session.repoint(runs)
    }

    /// The clip "A" rendered into "f NR" with an added gain of 1 dB.
    func rendered() throws -> Session {
        var session = try placed()
        try render(&session, stem: "f NR")
        return session
    }

    /// The shown words as text, timeline range, and word ID.
    func shown(_ session: Session) -> [String] {
        session.words().map { "\($0.text) \($0.range) \($0.occurrence.word)" }
    }

    /// The frames that a cut of the first shown word cuts, on a copy of `session`.
    func cutOfFirstWord(_ session: Session) throws -> [Range<Frames>] {
        var copy = session
        return try copy.cutWords([try #require(copy.words().first).occurrence])
    }

    /// C1. Each new file gets the run file as source, the run start as offset, the treatment, and
    /// the added gain of its run: 0 dB for a run with no second pass, 1.5 dB for a run with one.
    @Test func renderWritesTheOrigin() throws {
        var session = try placed()
        try session.place(Clip(id: "B", file: "f", start: 200_000, offset: 5_000_000, length: 100_000), on: "t")

        try render(&session, ["A", "B"], stem: "f NR", dB: [0, 1.5])

        let none = try #require(Gain(dB: 0))
        let second = try #require(Gain(dB: 1.5))
        #expect(
            session.files["f NR"]?.origin
                == RenderOrigin(source: "f", offset: 520_000, treatment: noise, addedGain: none))
        #expect(
            session.files["f NR 2"]?.origin
                == RenderOrigin(source: "f", offset: 4_520_000, treatment: noise, addedGain: second))
        #expect(session.clip("A")?.clip.gain == Gain(dB: 10) && session.clip("B")?.clip.gain == second)
        #expect(session.fileVersion == 12)
    }

    /// C2. A trim, a move, and a ripple of a rendered clip change no pool record. Restore Original
    /// then puts the clip on the root at the frame that it plays, with the gain of the user.
    @Test func restoreAfterEachEdit() throws {
        var session = try rendered()
        let pool = session.files

        try session.trim("A", to: 10_000..<90_000)
        try session.move("A", to: "t", start: 200_000)
        try session.rippleDelete(0..<50_000, on: ["t"])

        #expect(session.files == pool, "the edits change no pool record")
        let edited = try #require(session.clip("A")?.clip)
        #expect(edited.file == "f NR" && edited.offset == 490_000 && edited.start == 150_000)
        try session.restoreOriginals(["A"])
        let restored = try #require(session.clip("A")?.clip)
        #expect(restored.file == "f" && restored.offset == 1_010_000)
        #expect(restored.start == 150_000 && restored.length == 80_000 && restored.gain == Gain(dB: 10))
    }

    /// C12. Words imported before a render stay on the root: a render, a second level, a lower by
    /// one level, and Restore Original each show the same words and cut the same frames.
    @Test func wordsStayThroughRenderAndRestore() throws {
        var session = try placed()
        session.addWords([(1, 1_010_000..<1_020_000, "Hello"), (2, 1_050_000..<1_060_000, "there")], file: "f")
        let words = shown(session)
        let cut = try cutOfFirstWord(session)
        #expect(cut == [10_000..<20_000])

        try render(&session, stem: "f NR")
        #expect(shown(session) == words, "after the render")
        #expect(try cutOfFirstWord(session) == cut, "after the render")
        #expect(session.transcripts[TranscriptID(1)]?.words?["f NR"] == nil, "a render copies no word")
        try render(&session, stem: "f NR NR")
        #expect(session.origins(of: "A").count == 2)
        #expect(shown(session) == words, "after a second level")
        #expect(try cutOfFirstWord(session) == cut, "after a second level")
        try session.lower(["A"], levels: 1)
        #expect(shown(session) == words, "after a lower")
        #expect(try cutOfFirstWord(session) == cut, "after a lower")
        try session.restoreOriginals(["A"])
        #expect(shown(session) == words, "after the restore")
        #expect(try cutOfFirstWord(session) == cut, "after the restore")
    }

    /// C12. An import over a rendered clip writes root frames to the root, so the words stay at the
    /// restore.
    @Test func importAfterRenderWritesTheRoot() throws {
        var session = try rendered()
        let json = #"{"words":[{"word":"Hello","start":0.25,"end":0.5}]}"#

        try session.importTranscript(try TranscriptFile(data: Data(json.utf8)), name: "t", track: "t", at: 0)

        let words = session.transcripts[TranscriptID(1)]?.words
        #expect(words?["f"]?.all == [Anchor(number: 1, range: 1_012_000..<1_024_000, text: "Hello")])
        #expect(words?["f NR"] == nil)
        let shown = shown(session)
        #expect(session.words().map(\.range) == [12_000..<24_000])
        try session.restoreOriginals(["A"])
        #expect(self.shown(session) == shown)
    }

    /// C2. A split changes no pool record: both halves keep the origin of the rendered file. Restore
    /// Original puts each half on the root at the frame that it played, with the gain of the user.
    @Test func splitKeepsTheOrigin() throws {
        var session = try rendered()
        let origin = RenderOrigin(source: "f", offset: 520_000, treatment: noise, addedGain: try #require(Gain(dB: 1)))
        #expect(session.files["f NR"]?.origin == origin)
        #expect(session.clip("A")?.clip.gain == Gain(dB: 11))
        let pool = session.files

        let right = try session.split("A", at: 40_000)

        #expect(session.files == pool, "a split changes no pool record")
        #expect(session.origins(of: "A") == [origin] && session.origins(of: right) == [origin])

        try session.restoreOriginals(["A", right])

        let left = try #require(session.clip("A")?.clip)
        let half = try #require(session.clip(right)?.clip)
        #expect(left.file == "f" && left.offset == 1_000_000 && left.start == 0 && left.length == 40_000)
        #expect(half.file == "f" && half.offset == 1_040_000 && half.start == 40_000 && half.length == 60_000)
        #expect(left.gain == Gain(dB: 10) && half.gain == Gain(dB: 10))
        #expect(session.origins(of: "A").isEmpty && session.origins(of: right).isEmpty)
    }
}
