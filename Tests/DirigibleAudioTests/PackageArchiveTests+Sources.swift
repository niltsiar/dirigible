import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Which pool files a package job converts, and how it counts them (decision 0072, run criteria
/// C10, C12, and C13).
extension PackageArchiveTests {
    /// A drift fix can write a WAV that is longer than its pool entry, and the media check accepts
    /// it. The archive converts it, and the unarchive gives back each of its frames. Fail value:
    /// the archive keeps it as damaged.
    @Test func anArchiveConvertsAWAVLongerThanItsEntry() throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        try session.addFile(try fixture.addWAV("long.wav", frames: 30_001, length: 30_000, seed: 1))
        let data = try wavData(fixture.url("Clips/long.wav"))

        let report = try archivePackage(&session, in: fixture.package, save: fixture.save)

        try #require(report.converted == ["long.wav"], "\(report)")
        #expect(try fixture.names() == ["long.flac"])
        #expect(try unarchivePackage(&session, in: fixture.package, save: fixture.save).converted == ["long.wav"])
        #expect(try wavData(fixture.url("Clips/long.wav")) == data, "each frame of the WAV comes back")
    }

    /// The FLAC of a WAV that is longer than its pool entry: the unarchive converts it with each of
    /// its frames. Fail value: the STREAMINFO frames differ from the entry, so the unarchive keeps
    /// the FLAC as damaged.
    @Test func anUnarchiveConvertsAFLACLongerThanItsEntry() throws {
        let fixture = try ArchiveFixture()
        let file = try fixture.addWAV("long.wav", frames: 30_001, seed: 1)
        let data = try wavData(fixture.url("Clips/long.wav"))
        #expect(try archiveClip(file, in: fixture.package, rate: ArchiveFixture.rate))
        var session = Session(sampleRate: ArchiveFixture.rate)
        try session.addFile(AudioFile(id: file.id, path: file.path, layout: file.layout, length: 30_000))
        session.archive = .flac
        _ = try fixture.save(session)

        let report = try unarchivePackage(&session, in: fixture.package, save: fixture.save)

        try #require(report.converted == ["long.wav"], "\(report)")
        #expect(try wavData(fixture.url("Clips/long.wav")) == data)
        #expect(try fixture.stored().archive == nil)
    }

    /// An archive that converts no file leaves no attribute: a pool of only a 16-bit WAV changes
    /// no file, and a pool whose WAVs are all damaged ends with no attribute. Fail value: the
    /// session reads as archived with no FLAC on disk.
    @Test func anArchiveThatConvertsNoFileLeavesNoAttribute() throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        try session.addFile(try fixture.addWAV("b.wav", bits: 16, seed: 2))
        _ = try fixture.save(session)
        let before = try fixture.sessionFile()

        let report = try archivePackage(&session, in: fixture.package, save: fixture.save)

        try #require(try fixture.sessionFile() == before, "session.xml changed")
        #expect(report.kept == ["b.wav": .notArchivable] && report.converted.isEmpty, "\(report)")
        #expect(try session.archive == nil && fixture.stored().archive == nil)

        try session.addFile(try fixture.addWAV("short.wav", frames: 20_000, length: 30_000, seed: 3))
        _ = try fixture.save(session)
        let damaged = try archivePackage(&session, in: fixture.package, save: fixture.save)

        #expect(damaged.kept["short.wav"] == .damaged(frames: 20_000), "\(damaged)")
        #expect(try session.archive == nil && fixture.stored().archive == nil, "no FLAC, so no attribute")
        #expect(try fixture.names() == ["b.wav", "short.wav"])
    }

    /// The pool entry `foo.flac` of other audio next to the missing pool WAV `foo.wav`, as an older
    /// build or a hand edit saved them: no job converts, unlinks, or counts that FLAC for the WAV
    /// entry. Fail value: the unarchive converts the FLAC of the other entry to `foo.wav` and
    /// unlinks it.
    @Test func noJobConvertsTheFLACOfAnotherPoolEntry() throws {
        let fixture = try ArchiveFixture()
        let other = try fixture.addWAV("other.wav", seed: 2)
        #expect(try archiveClip(other, in: fixture.package, rate: ArchiveFixture.rate))
        try FileManager.default.moveItem(at: fixture.url("Clips/other.flac"), to: fixture.url("Clips/foo.flac"))
        var session = Session(sampleRate: ArchiveFixture.rate)
        try session.addFile(AudioFile(id: "a", path: "foo.wav", layout: .mono, length: 30_000))
        try session.addFile(AudioFile(id: "b", path: "other.flac", layout: .mono, length: 30_000))
        _ = try fixture.save(session)
        // An edit refuses a pool path at the FLAC name of a pool WAV, and the reader keeps one.
        let xml = try String(contentsOf: fixture.url("session.xml"), encoding: .utf8)
        try xml.replacingOccurrences(of: #"path="other.flac""#, with: #"path="foo.flac""#)
            .write(to: fixture.url("session.xml"), atomically: true, encoding: .utf8)
        session = try fixture.stored()
        try #require(Set(session.files.values.map(\.path)) == ["foo.wav", "foo.flac"])
        let flac = try fixture.contents(of: ["Clips/foo.flac"])

        let report = try unarchivePackage(&session, in: fixture.package, save: fixture.save)

        try #require(report.converted.isEmpty, "\(report)")
        #expect(report.kept == ["foo.wav": .missing, "foo.flac": .notWAV], "\(report)")
        #expect(try fixture.contents(of: ["Clips/foo.flac"]) == flac)
        let archive = try archivePackage(&session, in: fixture.package, save: fixture.save)
        #expect(archive.kept == ["foo.wav": .missing, "foo.flac": .notWAV] && archive.converted.isEmpty, "\(archive)")
        #expect(try fixture.names() == ["foo.flac"] && fixture.contents(of: ["Clips/foo.flac"]) == flac)
        #expect(try fixture.stored().archive == nil)

        try fixture.addWAV("foo.wav", seed: 3)
        let wav = try fixture.contents(of: ["Clips/foo.wav"])
        let present = try archivePackage(&session, in: fixture.package, save: fixture.save)
        let reason = present.kept["foo.wav"]
        #expect(present.converted.isEmpty && reason != nil && reason != .missing, "\(present)")
        #expect(try fixture.contents(of: ["Clips/foo.flac", "Clips/foo.wav"]) == flac.merging(wav) { $1 })
    }

    /// Two pool entries with one path name one file on disk: each job converts it and counts its
    /// bytes once. Fail value: the archive reports the path twice and doubles the freed and the
    /// written bytes.
    @Test func eachJobCountsAFileOfTwoEntriesOnce() throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        let file = try fixture.addWAV("a.wav", seed: 1)
        try session.addFile(file)
        try session.addFile(AudioFile(id: "a2", path: "a.wav", layout: file.layout, length: file.length))
        let wav = try fileSizes(of: fixture.url("Clips/a.wav"), name: "a.wav")

        let report = try archivePackage(&session, in: fixture.package, save: fixture.save)

        try #require(report.converted == ["a.wav"], "\(report)")
        let flac = try fileSizes(of: fixture.url("Clips/a.flac"), name: "a.flac")
        #expect(report.bytesFreed == wav.freed && report.bytesWritten == flac.bytes, "\(report)")
        let back = try unarchivePackage(&session, in: fixture.package, save: fixture.save)
        #expect(back.converted == ["a.wav"] && back.bytesFreed == flac.freed, "\(back)")
        #expect(try fixture.names() == ["a.wav"])
    }
}
