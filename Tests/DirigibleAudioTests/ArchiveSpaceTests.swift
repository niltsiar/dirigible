import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The disk rule and the freed bytes of the package jobs (decision 0072, run criteria C11 and C12).
/// The private bytes of a file are the bytes that its unlink frees: 0 for an APFS clone.
struct ArchiveSpaceTests {
    /// The WAV and FLAC bytes of the 29 clips of the `interview-jm-oct` corpus package (probe-flac).
    static let corpus: [(wav: Int64, flac: Int64)] = [
        (2_451_664, 951_042), (714_508, 417_493), (1_104_160, 553_845), (666_142, 231_805), (252_358, 135_783),
        (1_980_826, 1_228_364), (1_980_826, 1_228_364), (2_609_188, 1_636_165), (2_609_188, 1_701_261),
        (4_009_912, 2_564_589), (5_188_096, 3_024_935), (1_300_096, 787_830), (1_300_096, 787_830),
        (1_300_096, 785_472), (1_849_912, 1_151_241), (1_300_096, 812_965), (1_876_096, 1_131_075),
        (7_780_096, 5_144_515), (7_780_096, 5_144_515), (7_780_096, 5_144_515), (1_287_196, 571_183),
        (7_899_136, 1_140_005), (7_901_848, 1_405_288), (7_932_562, 4_161_603), (7_935_286, 3_264_446),
        (84_375_472, 43_560_772), (84_378_352, 35_114_584), (1_158_377_692, 598_279_203),
        (1_158_377_686, 493_926_421),
    ]

    @Test func theNeedsOfTheWorkedFixture() {
        let corpus = Self.corpus
        #expect(diskNeed(corpus.map { ($0.wav, $0.wav) }) == 2_158_377_692, "archive, no clone")
        #expect(diskNeed(corpus.map { ($0.wav, $0.flac) }) == 2_956_590_872, "unarchive, no clone")
        #expect(diskNeed(corpus.map { ($0.wav, 0) }) == 3_574_298_778, "each source a clone")
        #expect(diskNeed([]) == 0, "a job with no file needs no space")
    }

    @Test func eachJobRunsAtItsNeedAndRefusesOneByteLess() throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        try session.addFile(try fixture.addWAV("a.wav", seed: 1))
        try session.addFile(try fixture.addWAV("b.wav", frames: 60_000, seed: 2))
        _ = try fixture.save(session)
        let files = try fixture.contents(of: ["Clips/a.wav", "Clips/b.wav"])
        let sizes = try ["a.wav", "b.wav"].map { try fileSizes(of: fixture.url("Clips/\($0)"), name: $0) }
        let need = diskNeed(sizes.map { ($0.bytes, $0.freed) })
        var seams = ArchiveSeams()

        seams.freeBytes = { _ in need - 1 }
        #expect(throws: ArchiveFault.space(need: need, free: need - 1)) {
            try archivePackage(
                &session, in: fixture.package, progress: { _ in }, isStopped: { false }, save: fixture.save,
                seams: seams)
        }
        #expect(try fixture.contents(of: Array(files.keys)) == files)
        #expect(try fixture.stored().archive == nil)
        seams.freeBytes = { _ in need }
        #expect(
            try archivePackage(
                &session, in: fixture.package, progress: { _ in }, isStopped: { false }, save: fixture.save,
                seams: seams
            ).converted == ["a.wav", "b.wav"])

        let flacs = try fixture.contents(of: ["Clips/a.flac", "Clips/b.flac"])
        let wavBytes = session.files.values.sorted { $0.path < $1.path }.map {
            wavFileBytes(frames: Int64($0.length.count), channels: $0.layout.channelCount)
        }
        let flacSizes = try ["a.flac", "b.flac"].map { try fileSizes(of: fixture.url("Clips/\($0)"), name: $0) }
        let back = diskNeed(zip(wavBytes, flacSizes).map { ($0, $1.freed) })
        seams.freeBytes = { _ in back - 1 }
        #expect(throws: ArchiveFault.space(need: back, free: back - 1)) {
            try unarchivePackage(
                &session, also: [], in: fixture.package, progress: { _ in }, isStopped: { false },
                save: fixture.save, seams: seams)
        }
        #expect(try fixture.contents(of: Array(flacs.keys)) == flacs)
        seams.freeBytes = { _ in back }
        #expect(
            try unarchivePackage(
                &session, also: [], in: fixture.package, progress: { _ in }, isStopped: { false },
                save: fixture.save, seams: seams
            ).converted == ["a.wav", "b.wav"])
    }

    @Test func theFreedBytesCountThePrivateBytes() throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        try session.addFile(try fixture.addWAV("a.wav", frames: 200_000, seed: 1))
        let outside = fixture.folder.url.appending(path: "outside.wav")
        let clone = fixture.url("Clips/b.wav")
        try session.addFile(try fixture.addWAV("b.wav", frames: 200_000, seed: 2))
        try FileManager.default.moveItem(at: clone, to: outside)
        try #require(clonefile(outside.path, clone.path, 0) == 0, "the test folder is on APFS")
        let allocated = try fileSizes(of: fixture.url("Clips/a.wav"), name: "a.wav").allocated
        #expect(try fileSizes(of: clone, name: "b.wav").freed == 0, "an APFS clone frees nothing")

        let report = try archivePackage(&session, in: fixture.package, save: fixture.save)

        #expect(report.converted == ["a.wav", "b.wav"])
        #expect(abs(report.bytesFreed - allocated) <= 4_096, "the WAV with no clone, and 0 for the clone")
        let flacs = try ["a.flac", "b.flac"].map { try Data(contentsOf: fixture.url("Clips/\($0)")).count }
        #expect(report.bytesWritten == Int64(flacs.reduce(0, +)))
    }

    /// C12, the `du` gate of the replay. The Apple codec can leave megabytes allocated past the end
    /// of a large file (probe 2026-11-25: about 14 MB after a 138 MB FLAC, 7 to 16 MB after a 138 MB
    /// WAV, none after a 104 MB WAV), so 480 s of stereo noise makes both files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func eachJobLeavesNoAllocatedBytesPastTheEndOfItsFile() throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        try session.addFile(try fixture.addWAV("a.wav", frames: 480 * ArchiveFixture.rate, channels: 2, seed: 1))
        func excess(_ name: String) throws -> Int64 {
            var info = stat()
            try #require(lstat(fixture.url("Clips/\(name)").path, &info) == 0)
            return Int64(info.st_blocks) * 512 - info.st_size
        }

        #expect(try archivePackage(&session, in: fixture.package, save: fixture.save).converted == ["a.wav"])
        let flac = try excess("a.flac")
        #expect(flac < 4_096, "the FLAC has \(flac) allocated bytes past its end")
        #expect(try unarchivePackage(&session, in: fixture.package, save: fixture.save).converted == ["a.wav"])
        let wav = try excess("a.wav")
        #expect(wav < 4_096, "the WAV has \(wav) allocated bytes past its end")
    }

    @Test func aVolumeWithNoPrivateSizeCountsTheAllocatedBytes() throws {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        try session.addFile(try fixture.addWAV("a.wav", seed: 1))
        try session.addFile(try fixture.addWAV("b.wav", frames: 60_000, seed: 2))
        _ = try fixture.save(session)
        let allocated = try ["a.wav", "b.wav"].map { try fileSizes(of: fixture.url("Clips/\($0)"), name: $0) }
        var seams = ArchiveSeams()
        seams.sizes = { url, name throws(ClipArchiveFault) in
            var sizes = try fileSizes(of: url, name: name)
            sizes.privateBytes = nil
            return sizes
        }
        let need = diskNeed(allocated.map { ($0.bytes, $0.allocated) })
        seams.freeBytes = { _ in need - 1 }
        #expect(throws: ArchiveFault.space(need: need, free: need - 1)) {
            try archivePackage(
                &session, in: fixture.package, progress: { _ in }, isStopped: { false }, save: fixture.save,
                seams: seams)
        }

        seams.freeBytes = { _ in .max }
        let report = try archivePackage(
            &session, in: fixture.package, progress: { _ in }, isStopped: { false }, save: fixture.save, seams: seams)
        #expect(report.bytesFreed == allocated.map(\.allocated).reduce(0, +))
    }
}
