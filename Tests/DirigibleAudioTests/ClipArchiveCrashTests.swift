import AVFoundation
import CryptoKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Run criterion C10, file part: a crash after each step of one clip conversion leaves a clip
/// that reads with its full length, and the next call of the same direction ends the job.
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

    /// The length of the clip in the order of the resolver: the WAV when it is there, else the FLAC.
    private func readLength(_ clip: ArchiveClip) throws -> Int {
        let url = FileManager.default.fileExists(atPath: clip.wav.path) ? clip.wav : clip.flac
        return Int(try AVAudioFile(forReading: url).length)
    }
}
