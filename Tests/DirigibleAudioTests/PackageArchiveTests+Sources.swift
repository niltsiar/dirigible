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
}
