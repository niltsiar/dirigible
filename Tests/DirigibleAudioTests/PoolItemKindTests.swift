import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A package from another person can hold a FIFO or a device in `Clips/` or `Transcripts/`, also
/// behind a link. The read of the package refuses it, so no later read of a pool file waits for a
/// writer.
@MainActor
struct PoolItemKindTests {
    let folder: TemporaryFolder
    let url: URL

    /// A package whose pool names `a.wav` and `sub/b.wav`, with the folders `Clips/sub` and
    /// `Transcripts`, and no audio.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        for path in ["a.wav", "sub/b.wav"] {
            try session.addFile(AudioFile(id: FileID(path), path: path, layout: .mono, length: 6000))
        }
        try session.write(to: url)
        for path in ["Clips/sub", "Transcripts"] {
            try FileManager.default.createDirectory(at: url.appending(path: path), withIntermediateDirectories: true)
        }
    }

    /// The result of `Session(contentsOf:)`, or nil when the read waited for a writer of `fifo`.
    func read(waitingOn fifo: URL) async -> Result<Session, SessionFileError>? {
        let url = url
        return await valueWithNoWriter(of: fifo) {
            Result { () throws(SessionFileError) in try Session(contentsOf: url) }
        }
    }

    /// A named pool file, a named pool file in a subfolder, a stray entry of `Clips/`, and a stray
    /// entry of `Transcripts/`.
    @Test(arguments: ["Clips/a.wav", "Clips/sub/b.wav", "Clips/stray.wav", "Transcripts/stray.xml"])
    func aFIFOIsRefusedAtOnce(_ path: String) async throws {
        let fifo = url.appending(path: path)
        try makeFIFO(at: fifo)

        #expect(await read(waitingOn: fifo) == .failure(.unsafeItem(path)))
    }

    @Test(arguments: ["Clips/a.wav", "Clips/sub/b.wav", "Transcripts/t.xml"])
    func aLinkToAFIFOIsRefusedAtOnce(_ path: String) async throws {
        let fifo = folder.url.appending(path: "outside.fifo")
        try makeFIFO(at: fifo)
        try FileManager.default.createSymbolicLink(at: url.appending(path: path), withDestinationURL: fifo)

        #expect(await read(waitingOn: fifo) == .failure(.unsafeItem(path)))
    }

    /// A read of `/dev/zero` never ends, and a folder in `Transcripts/` is no transcript file.
    @Test func aLinkToADeviceAndAFolderInTranscriptsAreRefused() throws {
        try FileManager.default.createSymbolicLink(
            at: url.appending(path: "Clips/a.wav"), withDestinationURL: URL(filePath: "/dev/zero"))
        #expect(throws: SessionFileError.unsafeItem("Clips/a.wav")) { try Session(contentsOf: url) }

        try FileManager.default.removeItem(at: url.appending(path: "Clips/a.wav"))
        try FileManager.default.createDirectory(
            at: url.appending(path: "Transcripts/t.xml"), withIntermediateDirectories: true)
        #expect(throws: SessionFileError.unsafeItem("Transcripts/t.xml")) { try Session(contentsOf: url) }
    }

    /// A link to a regular file and a subfolder stay allowed (decisions 0042 and 0047), and a
    /// dangling link reads as a missing file.
    @Test func aLinkToAFileADanglingLinkAndASubfolderStayAllowed() throws {
        let outside = folder.url.appending(path: "outside.wav")
        try Data("RIFF".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: url.appending(path: "Clips/a.wav"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(
            at: url.appending(path: "Clips/sub/b.wav"), withDestinationURL: folder.url.appending(path: "gone.wav"))
        try FileManager.default.createSymbolicLink(
            at: url.appending(path: "Transcripts/t.xml"), withDestinationURL: outside)

        let session = try Session(contentsOf: url)

        #expect(Set(session.files.values.map(\.path)) == ["a.wav", "sub/b.wav"])
    }

    /// The placement of a segment whose CAF is gone reads the WAV of the segment (decision 0071).
    /// A FIFO at that WAV stops the read of the package before the placement.
    @Test func aFIFOStemWAVStopsThePlacementAtOnce() async throws {
        let package = try RawRemovalCrashTests.take()
        let (source, url) = (package.url, package.folder.url.appending(path: "Copy.dirigible"))
        try await offMainActor {
            let outcome = completeTake(of: try Session(contentsOf: source), lock: try PackageLock(source), level: false)
            {
                _ throws(SessionFileError) in
                // The process dies here: the copy is the package at that instant.
                do { try FileManager.default.copyItem(at: source, to: url) } catch { Issue.record(error) }
                throw .writeFailed(step: "crash", errno: EIO)
            }
            #expect(outcome.error == .file(.writeFailed(step: "crash", errno: EIO)))
        }
        try #require(try Session(contentsOf: url).recording?.take == 1, "the crash leaves the take pending")
        try #require(try RawRemovalCrashTests.record(RawRemovalCrashTests.segments[0], in: url) != nil)
        try FileManager.default.removeItem(at: url.appending(path: "Capture/take1-1-1.caf"))
        let fifo = url.appending(path: "Clips/take1-1-1.wav")
        try makeFIFO(at: fifo)
        let name = RawRemovalCrashTests.segments[0]

        let value = await valueWithNoWriter(of: fifo) { () -> SessionFileError? in
            let session: Session
            do throws(SessionFileError) {
                session = try Session(contentsOf: url)
            } catch {
                return error
            }
            guard let recording = session.recording else { return nil }
            _ = try? placeSegment(name, to: .aligned(recording, track: "t1"), of: session, in: url)
            return nil
        }

        #expect(value == .some(.unsafeItem("Clips/take1-1-1.wav")))
    }
}
