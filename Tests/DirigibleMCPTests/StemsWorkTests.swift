import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore
@testable import DirigibleMCP

/// The argument rules and the texts of `dirigible export-stems` and `export_stems` (criteria C1,
/// C2, C5, C9, and C15): `StemsWork` is their one owner.
struct StemsWorkTests {
    static func work(
        out: String = "/tmp/stems", by: String? = nil, format: String? = nil, bits: Int? = nil, rate: Int? = nil,
        from: Int = 0, to: Int? = nil, tracks: [TrackID] = [], spelling: OptionSpelling = .cli
    ) throws(ToolError) -> StemsWork {
        try StemsWork(
            out: out, by: by, format: format, bits: bits, mono: false, rate: rate, from: from, to: to, tracks: tracks,
            allowMissing: true, spelling: spelling)
    }

    static func refusal(_ make: () throws(ToolError) -> StemsWork) -> String? {
        do throws(ToolError) {
            _ = try make()
            return nil
        } catch {
            return error.message
        }
    }

    /// Host (dialogue) and Guest with a clip at 0..<48000, Bed muted, and Empty with no clip.
    static func session() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 48_000))
        for (id, name) in [("h", "Host"), ("g", "Guest"), ("b", "Bed"), ("e", "Empty")] as [(TrackID, String)] {
            try session.addTrack(id, name: name, layout: .mono)
            if id != "e" {
                try session.place(Clip(id: ClipID(id.rawValue), file: "f", start: 0, offset: 0, length: 48_000), on: id)
            }
        }
        try session.setRole(.dialogue, tracks: ["h"])
        try session.setMuted(true, tracks: ["b"])
        return session
    }

    /// C9: each refused value is a usage error with the text of its option, before any file work.
    @Test func theArgumentRules() throws {
        #expect(
            Self.refusal { () throws(ToolError) in try Self.work(format: "mp3") } == "--format must be wav or flac.")
        #expect(
            Self.refusal { () throws(ToolError) in try Self.work(format: "mp3", spelling: .tool) }
                == "format must be wav or flac.")
        #expect(Self.refusal { () throws(ToolError) in try Self.work(bits: 20) } == "--bits must be 16 or 24.")
        #expect(Self.refusal { () throws(ToolError) in try Self.work(by: "stem") } == "--by must be track or role.")
        #expect(
            Self.refusal { () throws(ToolError) in try Self.work(rate: 22_050) } == "--rate must be 44100 or 48000.")
        for out in ["/tmp/Show.dirigible/stems", "/tmp/Show.dirigible", "/tmp/a.DIRIGIBLE/b/stems"] {
            #expect(Self.refusal { () throws(ToolError) in try Self.work(out: out) } == ExportText.insidePackageMessage)
        }
        let long = "/tmp/" + String(repeating: "s", count: 207)
        #expect(
            Self.refusal { () throws(ToolError) in try Self.work(out: long) }
                == "The --out folder name is over 206 bytes.")
        #expect(Self.refusal { () throws(ToolError) in try Self.work(out: String(long.dropLast())) } == nil)
        let work = try Self.work()
        #expect(
            work.grouping == .track
                && work.options == StemOptions(format: .wav(.bits24), layout: .stereo, rate: .session))
        let flac = try Self.work(by: "role", format: "flac", bits: 16, rate: 44_100)
        #expect(
            flac.grouping == .role
                && flac.options == StemOptions(format: .flac(.bits16), layout: .stereo, rate: .hz44100))
        let session = try Self.session()
        #expect(throws: Never.self) { try Self.work(from: 100, to: 200).source(in: session) }
        for (from, to) in [(200, 100), (-1, nil), (48_000, nil)] as [(Int, Int?)] {
            #expect(
                Self.refusal { () throws(ToolError) in
                    _ = try Self.work(from: from, to: to).source(in: session)
                    return try Self.work()
                } == ExportText.rangeMessage(end: session.end, spelling: .cli))
        }
        #expect(
            Self.refusal { () throws(ToolError) in
                _ = try Self.work(tracks: ["nope"]).source(in: session)
                return try Self.work()
            } == ExportText.noTrackMessage("nope"))
    }

    /// C1, C5, C15: the stdout line of each file names the file and its track IDs; then stderr has
    /// the fault, unheard, empty-stem, and peak lines. C2: a role plan with no role set has the note.
    @Test func theTextListsEachFileThenTheWarnings() throws {
        let session = try Self.session()
        let work = try Self.work()
        let source = try work.source(in: session)
        let plan = try #require(
            session.stemPlan(by: .track, tracks: nil, range: source.range, titles: .english, limit: 204))
        let files = [
            StemFile(name: "01 Host.wav", tracks: ["h"], samplePeak: 0.5),
            StemFile(name: "02 Guest.wav", tracks: ["g"], samplePeak: 1.2),
        ]
        let result = StemsResult(plan: plan, files: files, faults: ["f": .missing], mixPeak: 1.5)
        let lines = try work.lines(of: result, session: session, source: source)
        #expect(lines.stdout == ["01 Host.wav\th", "02 Guest.wav\tg"])
        #expect(
            lines.stderr == ExportText.faultLines(["f": .missing], in: session) + [
                "Warning: 1 track is muted or not soloed and is not in the export.",
                "Warning: track e (Empty) has no clip in the range, so it has no stem file.",
                "Warning: 02 Guest.wav is over 0 dBFS (peak +1.6 dB): it clips, so the stems do not add up to the mix.",
                "Warning: the mix of the stems is over 0 dBFS (peak +3.5 dB): the stems do not add up to a mix export.",
            ])
        let role = try #require(
            session.stemPlan(by: .role, tracks: ["g"], range: source.range, titles: .english, limit: 204))
        let none = StemsResult(
            plan: role, files: [StemFile(name: "No Role.wav", tracks: ["g"], samplePeak: 0.5)], faults: [:],
            mixPeak: nil)
        let guest = try Self.work(tracks: ["g"])
        let roleLines = try guest.lines(of: none, session: session, source: guest.source(in: session))
        #expect(roleLines.stdout == ["No Role.wav\tg"])
        #expect(roleLines.stderr == ["Note: no heard track of the set has a role, so one file holds them all."])
    }
}
