import AVFoundation
import CryptoKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Run criterion C10, file and package parts: a crash after each step of one clip conversion, or
/// around the save of a package job, leaves each clip whole, and the next call of the same
/// direction ends the job.
struct ClipArchiveCrashTests {
    @Test(arguments: ClipArchiveStep.allCases)
    func aCrashAfterEachArchiveStepKeepsTheClipAndTheNextArchiveEndsIt(step: ClipArchiveStep) throws {
        let clip = try ArchiveClip(channels: 2, rate: 48_000)
        let data = try wavData(clip.wav)
        var reached = false

        #expect(
            try !archiveClip(
                clip.file, in: clip.package, rate: 48_000,
                after: { at, _ in
                    reached = reached || at == step
                    return at != step
                }))
        #expect(reached)
        #expect(try readLength(clip) == ArchiveClip.frames)
        #expect(try clip.names().filter(isArchiveTemporary).count <= 1)

        #expect(try archiveClip(clip.file, in: clip.package, rate: 48_000))
        #expect(try clip.names().filter { !isArchiveTemporary($0) } == ["a.flac"])
        #expect(try streamInfo(clip.flac).md5 == Data(Insecure.MD5.hash(data: data)))
    }

    @Test(arguments: ClipArchiveStep.allCases)
    func aCrashAfterEachUnarchiveStepKeepsTheClipAndTheNextUnarchiveEndsIt(step: ClipArchiveStep) throws {
        let clip = try ArchiveClip(channels: 2, rate: 48_000)
        let data = try wavData(clip.wav)
        #expect(try archiveClip(clip.file, in: clip.package, rate: 48_000))
        var reached = false

        #expect(
            try !unarchiveClip(
                clip.file, in: clip.package, rate: 48_000,
                after: { at, _ in
                    reached = reached || at == step
                    return at != step
                }))
        #expect(reached)
        #expect(try readLength(clip) == ArchiveClip.frames)
        #expect(try clip.names().filter(isArchiveTemporary).count <= 1)

        #expect(try unarchiveClip(clip.file, in: clip.package, rate: 48_000))
        #expect(try clip.names().filter { !isArchiveTemporary($0) } == ["a.wav"])
        #expect(try wavData(clip.wav) == data)
    }

    @Test func aCrashBeforeTheAttributeSaveLeavesNoFLACAndNoAttribute() throws {
        let (fixture, session) = try Self.package()
        var seams = ArchiveSeams()
        seams.after = { $0 != .checked }
        var copy = session

        #expect(throws: ArchiveFault.cancelled) {
            try archivePackage(
                &copy, in: fixture.package, progress: { _ in }, isStopped: { false }, save: fixture.save, seams: seams)
        }
        #expect(try fixture.names() == ["a.wav", "b.wav"])
        #expect(try fixture.stored().archive == nil)
    }

    @Test func aCrashAfterTheAttributeSaveKeepsEachClipWholeAndTheNextArchiveEndsIt() throws {
        let (fixture, session) = try Self.package()
        var seams = ArchiveSeams()
        seams.after = { $0 != .saved }
        var copy = session

        #expect(throws: ArchiveFault.cancelled) {
            try archivePackage(
                &copy, in: fixture.package, progress: { _ in }, isStopped: { false }, save: fixture.save, seams: seams)
        }
        var stored = try fixture.stored()
        #expect(stored.archive == .flac)
        try Self.expectWhole(stored, in: fixture)

        #expect(try archivePackage(&stored, in: fixture.package, save: fixture.save).converted == ["a.wav", "b.wav"])
        #expect(try fixture.names() == ["a.flac", "b.flac"])
    }

    @Test func aCrashAfterTheLastFileOfAnUnarchiveKeepsTheAttributeAndTheNextUnarchiveClearsIt() throws {
        let (fixture, saved) = try Self.package()
        var session = saved
        _ = try archivePackage(&session, in: fixture.package, save: fixture.save)
        var seams = ArchiveSeams()
        seams.after = { $0 != .converted }

        #expect(throws: ArchiveFault.cancelled) {
            try unarchivePackage(
                &session, also: [], in: fixture.package, progress: { _ in }, isStopped: { false },
                save: fixture.save, seams: seams)
        }
        var stored = try fixture.stored()
        #expect(stored.archive == .flac)
        #expect(try fixture.names() == ["a.wav", "b.wav"])
        try Self.expectWhole(stored, in: fixture)

        #expect(try unarchivePackage(&stored, in: fixture.package, save: fixture.save).converted.isEmpty)
        #expect(try fixture.stored().archive == nil)
    }

    /// A saved package with the pool WAVs `a.wav` and `b.wav`.
    private static func package() throws -> (ArchiveFixture, Session) {
        let fixture = try ArchiveFixture()
        var session = Session(sampleRate: ArchiveFixture.rate)
        try session.addFile(try fixture.addWAV("a.wav", seed: 1))
        try session.addFile(try fixture.addWAV("b.wav", channels: 2, seed: 2))
        _ = try fixture.save(session)
        return (fixture, session)
    }

    /// Each pool file reads with its full length at the name that `poolFileName` gives.
    private static func expectWhole(_ session: Session, in fixture: ArchiveFixture) throws {
        for file in session.files.values {
            let url = fixture.url(poolFileName(file, in: fixture.package).name)
            #expect(try AVAudioFile(forReading: url).length == AVAudioFramePosition(file.length.count), "\(file.path)")
        }
    }

    /// The length of the clip in the order of the resolver: the WAV when it is there, else the FLAC.
    private func readLength(_ clip: ArchiveClip) throws -> Int {
        let url = FileManager.default.fileExists(atPath: clip.wav.path) ? clip.wav : clip.flac
        return Int(try AVAudioFile(forReading: url).length)
    }
}
