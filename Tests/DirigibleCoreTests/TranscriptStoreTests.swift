import Foundation
import Testing

@testable import DirigibleCore

/// The transcript files of decision 0055 (run transcript-1, A10; criteria T13, T22, and T23).
struct TranscriptStoreTests {
    let one = TranscriptID(1)
    let package = FileManager.default.temporaryDirectory.appending(path: "TranscriptStore-\(UUID())/E.dirigible")
    var folder: URL { package.appending(path: "Transcripts") }

    /// The names in `Transcripts/` that do not start with ".".
    func files() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") })
    }

    /// The inode of the file of transcript 1 of `session`.
    func inode(_ session: Session) throws -> ino_t {
        let name = try #require(session.transcripts[one]?.file)
        var info = stat()
        try #require(lstat(folder.appending(path: "\(name).xml").path, &info) == 0)
        return info.st_ino
    }

    /// Clip "H" over file "h" and clip "G" over file "g", and transcript 1 with words in both files.
    func session() throws -> Session {
        var session = try transcriptSession()
        try session.place(Clip(id: "H", file: "h", start: 0, offset: 0, length: 500_000), on: "host")
        try session.place(Clip(id: "G", file: "g", start: 0, offset: 0, length: 500_000), on: "guest")
        session.addWords([(1, 10_000..<20_000, "Hello"), (2, 20_000..<30_000, "there")], file: "h")
        session.addWords([(3, 40_000..<50_000, "yes")], file: "g")
        return session
    }

    /// T22. Each of the five places that changes the words gives a new file name.
    @Test func aChangeOfTheWordsGivesANewName() throws {
        let session = try session()
        let name = try #require(session.transcripts[one]?.file)

        var edited = session
        edited.setWords([Anchor(number: 1, range: 10_000..<20_000, text: "Hello")], file: "h", transcript: one)
        #expect(edited.transcripts[one]?.file != name, "setWords")

        let excerpt = try session.excerpt(of: ["H"])
        let copied = try #require(excerpt.transcripts[one]?.file)
        #expect(copied != name, "Excerpt.init drops the words of g")

        let resampled = excerpt.resampled(to: 44_100, lengths: ["h": 918_750])
        #expect(resampled.transcripts[one]?.file != copied, "Excerpt.resampled")

        let record = AudioFile(id: "h2", path: "h2.wav", layout: .mono, length: 1_000_000)
        let mapped = try excerpt.mapped(to: ["h": record])
        let moved = try #require(mapped.transcripts[one]?.file)
        #expect(moved != copied, "Excerpt.mapped")

        var target = Session(sampleRate: 48_000)
        try target.addTrack("t", name: "T", layout: .mono)
        try target.addFile(record)
        try target.paste(mapped, at: 0, on: ["t"])
        #expect(target.transcripts[one]?.file != moved, "Session.paste")
    }

    /// T22. An assignment of the same words keeps the name, so the session stays equal.
    @Test func anAssignmentOfTheSameWordsKeepsEquality() throws {
        let session = try session()
        var same = session
        let words = try #require(session.transcripts[one]?.words?["h"]?.all)
        same.setWords(words, file: "h", transcript: one)
        #expect(same == session)
    }

    /// T22. A re-import over a span with no old words keeps the name of the old transcript.
    @Test func aReimportWithNoOldWordsKeepsTheName() throws {
        var session = try session()
        let name = try #require(session.transcripts[one]?.file)
        let file = try TranscriptFile(data: Data(#"{"words":[{"word":"late","start":9,"end":9.5}]}"#.utf8))
        try session.importTranscript(file, name: "late.json", track: "host", at: 0)
        #expect(session.transcripts[one]?.file == name)
    }

    /// T13. A transcript file reads back as the words that it was made from: "&", a folded tab,
    /// and overlapping anchors with one midpoint.
    @Test func fileRoundTrip() throws {
        let words: [FileID: Anchors] = [
            "h": Anchors([
                Anchor(number: 1, range: 0..<4_000, text: "R&B <x>"),
                Anchor(number: 2, range: 1_000..<3_000, text: " a b"),
                Anchor(number: 3, range: 1_500..<2_500, text: "inner"),
            ]),
            "g": Anchors([Anchor(number: 9, range: 5..<5, text: "zero")]),
        ]
        let data = TranscriptStore.encode(words)
        #expect(try TranscriptStore.decode(data) == words)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#"version="1""#) && text.contains("R&amp;B &lt;x&gt;"))
    }

    /// A file name is the canonical text of a UUID, so it never holds a path.
    @Test func aFileNameIsACanonicalUUID() {
        let uuid = "6F1C2A0E-0B6D-4E43-9C55-2A51E0C1D7B4"
        #expect(TranscriptFileName(uuid)?.description == uuid)
        for text in ["../x", uuid.lowercased(), uuid + ".xml", "", "/" + uuid] {
            #expect(TranscriptFileName(text) == nil, "\(text)")
        }
        #expect(TranscriptFileName(TranscriptFileName().description) != nil)
    }

    /// T13. A failed transcript file write throws before the replace, so `session.xml` keeps
    /// its bytes.
    @Test func aFailedTranscriptWriteKeepsTheOldSession() throws {
        var session = try session()
        session.transcripts = [:]
        try session.write(to: package)
        let before = try Data(contentsOf: package.appending(path: "session.xml"))
        try Data("not a folder".utf8).write(to: folder)

        #expect(throws: SessionFileError.self) { try self.session().write(to: package) }
        #expect(try Data(contentsOf: package.appending(path: "session.xml")) == before)
    }

    /// T22. A second save with no change of the words writes no transcript file.
    @Test func anAutosaveWritesNoTranscriptFile() throws {
        var session = try session()
        try session.write(to: package)
        let first = try inode(session)
        try session.setGain(Gain(dB: -3)!, track: "host")
        try session.write(to: package)
        #expect(try inode(session) == first)
        #expect(try files().count == 1)
    }

    /// T22. A change of the words writes a new file, and the old file stays.
    @Test func aChangeOfTheWordsWritesANewFile() throws {
        var session = try session()
        try session.write(to: package)
        let old = try #require(session.transcripts[one]?.file)
        try session.removeClips(["G"])
        try session.removeFile("g")
        try session.write(to: package)
        let new = try #require(session.transcripts[one]?.file)
        #expect(try files() == ["\(old).xml", "\(new).xml"])
        #expect(try Session(contentsOf: package).words().map(\.text) == ["Hello", "there"])
    }

    /// A temporary file of a crashed transcript write goes at the next sweep; a transcript file
    /// stays.
    @Test func aTemporaryTranscriptFileIsSwept() throws {
        let session = try session()
        try session.write(to: package)
        let temporary = folder.appending(path: ".session.xml.\(UUID().uuidString).tmp")
        try Data("part".utf8).write(to: temporary)
        session.removeTemporaryFiles(in: package)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(try files().count == 1)
    }

    /// T13. A session with no transcript makes no `Transcripts/` folder.
    @Test func noTranscriptMakesNoTranscriptsFolder() throws {
        var session = try session()
        session.transcripts = [:]
        try session.write(to: package)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// T13. A file of 0 bytes at the name (a crash before the data reached the disk) is written
    /// again.
    @Test func anEmptyFileAtTheNameIsWrittenAgain() throws {
        let session = try session()
        try session.write(to: package)
        let name = try #require(session.transcripts[one]?.file)
        try Data().write(to: folder.appending(path: "\(name).xml"))
        try session.write(to: package)
        let same = try Session(contentsOf: package) == session
        #expect(same)
    }

    /// T22. An open and a save with no edit keep the name and the file.
    @Test func anOpenAndSaveKeepsTheFile() throws {
        let session = try session()
        try session.write(to: package)
        let first = try inode(session)
        let opened = try Session(contentsOf: package)
        #expect(opened.transcripts[one]?.file == session.transcripts[one]?.file)
        try opened.write(to: package)
        #expect(try inode(opened) == first)
        let same = try Session(contentsOf: package) == session
        #expect(same)
    }

    /// T13 (0043). A revert to a backup loads the words of the backup from the package.
    @Test func aRevertLoadsTheWords() throws {
        let session = try session()
        try session.write(to: package)
        let backup = try #require(try Backup.keep(in: package))
        var later = session
        later.transcripts = [:]
        let lock = try PackageLock(package)
        let reverted = try withExtendedLifetime(lock) {
            try later.write(under: lock, backups: .none)
            return try backup.readForRevert(under: lock)
        }
        #expect(reverted.words() == session.words() && !reverted.words().isEmpty)
    }

    /// `session` saved, and the file of transcript 1 deleted.
    func saveAndDeleteTheFile(_ session: Session) throws {
        try session.write(to: package)
        try FileManager.default.removeItem(
            at: folder.appending(path: "\(try #require(session.transcripts[one]?.file)).xml"))
    }

    /// T23. A session whose transcript file is missing opens; the transcript shows no word and is
    /// reported; a file that comes back loads at the next open.
    @Test func aMissingTranscriptFileIsReported() throws {
        let session = try session()
        try session.write(to: package)
        let url = folder.appending(path: "\(try #require(session.transcripts[one]?.file)).xml")
        let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)

        let opened = try Session(contentsOf: package)
        #expect(opened.words().isEmpty)
        #expect(opened.transcriptsNotLoaded.map(\.id) == [one] && opened.transcriptsNotLoaded.map(\.name) == ["t1"])
        try data.write(to: url)
        let same = try Session(contentsOf: package) == session
        #expect(same, "the file came back")
    }

    /// T23. A save of a session with a transcript that did not load writes its reference again.
    @Test func theReferenceSurvivesASave() throws {
        let session = try session()
        try saveAndDeleteTheFile(session)
        var opened = try Session(contentsOf: package)
        try opened.setGain(Gain(dB: -3)!, track: "host")
        try opened.write(to: package)
        let text = try String(contentsOf: package.appending(path: "session.xml"), encoding: .utf8)
        let name = try #require(session.transcripts[one]?.file)
        #expect(text.contains(#"file="\#(name)""#) && text.contains(#"version="8""#))
        #expect(try Session(contentsOf: package).transcriptsNotLoaded.map(\.id) == [one])
    }

    /// T23 (0024 P7). A transcript file of a newer format does not load.
    @Test func aNewerTranscriptFileIsNotLoaded() throws {
        let session = try session()
        try session.write(to: package)
        let url = folder.appending(path: "\(try #require(session.transcripts[one]?.file)).xml")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(#"version="1""#))
        try Data(text.replacing(#"version="1""#, with: #"version="2""#).utf8).write(to: url)
        #expect(try Session(contentsOf: package).transcriptsNotLoaded.map(\.id) == [one])
    }

    /// A damaged transcript file with frames near Int.max: the session opens, and the transcript
    /// does not load.
    @Test func aFrameOutsideTheFrameRangeIsNotLoaded() throws {
        let session = try session()
        try session.write(to: package)
        let url = folder.appending(path: "\(try #require(session.transcripts[one]?.file)).xml")
        let text = try String(contentsOf: url, encoding: .utf8)
        let damaged = text.replacing("1 10000 20000 Hello", with: "1 \(Int.max - 1) \(Int.max) Hello")
            .replacing("2 20000 30000 there", with: "2 \(Int.max - 3) \(Int.max - 2) there")
        #expect(damaged.contains(" \(Int.max) Hello") && damaged.contains(" \(Int.max - 2) there"))
        try Data(damaged.utf8).write(to: url)

        let opened = try Session(contentsOf: package)
        #expect(opened.transcriptsNotLoaded.map(\.id) == [one] && opened.words().isEmpty)
        #expect(throws: SessionFileError.invalidSession(.wordOutsideFile("h"))) {
            try TranscriptStore.decode(Data(damaged.utf8))
        }
        let below = text.replacing("1 10000 20000 Hello", with: "1 -1 20000 Hello")
        #expect(below.contains("1 -1 20000 Hello"))
        #expect(throws: SessionFileError.invalidSession(.wordOutsideFile("h"))) {
            try TranscriptStore.decode(Data(below.utf8))
        }
    }

    /// T23. A file removed while its transcript did not load: the next load drops the words of
    /// that file with a new file name, and a transcript with no word left goes.
    @Test func aTranscriptOfARemovedFileStillLoads() throws {
        var session = try session()
        session.addWords([(1, 60_000..<70_000, "only")], file: "g", transcript: 2)
        try session.write(to: package)
        let names = try session.transcripts.mapValues { try Data(contentsOf: folder.appending(path: "\($0.file).xml")) }
        for transcript in session.transcripts.values {
            try FileManager.default.removeItem(at: folder.appending(path: "\(transcript.file).xml"))
        }
        var opened = try Session(contentsOf: package)
        try opened.removeClips(["G"])
        try opened.removeFile("g")
        try opened.write(to: package)
        for (id, data) in names {
            try data.write(to: folder.appending(path: "\(try #require(session.transcripts[id]?.file)).xml"))
        }

        let loaded = try Session(contentsOf: package)
        #expect(loaded.transcripts.keys.map(\.number) == [1], "transcript 2 had words only in g")
        #expect(loaded.words().map(\.text) == ["Hello", "there"])
        #expect(loaded.transcripts[one]?.file != session.transcripts[one]?.file, "the pruned words get a new name")
    }

    /// C12. A word keyed by a file with an origin does not load: no render writes one, and the
    /// words of a rendered file stay on its root (decision 0057 D11). The session still opens.
    @Test func wordOnRenderedFileIsNotLoaded() throws {
        var session = try session()
        let origin = RenderOrigin(source: "h", offset: 0, treatment: Treatment(.noise(.standard)), addedGain: .zero)
        try session.addFile(AudioFile(id: "h NR", path: "h NR.wav", layout: .mono, length: 500_000, origin: origin))
        try session.write(to: package)
        let url = folder.appending(path: "\(try #require(session.transcripts[one]?.file)).xml")
        let text = try String(contentsOf: url, encoding: .utf8)
        let damaged = text.replacing(#"file="h""#, with: #"file="h NR""#)
        #expect(damaged != text, "the fixture moves the words of h to h NR")
        try Data(damaged.utf8).write(to: url)

        let opened = try Session(contentsOf: package)

        #expect(opened.transcriptsNotLoaded.map(\.id) == [one] && opened.words().isEmpty)
    }
}
