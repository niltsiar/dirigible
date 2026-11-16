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

    /// Whether the folder at `path` opens for a listing. It still does after a `chmod` for root,
    /// or on a volume that ignores permissions, and then the tests of such a folder prove nothing.
    func lists(_ path: String) -> Bool {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if descriptor >= 0 { close(descriptor) }
        return descriptor >= 0
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

    /// A `Clips/` or `Transcripts/` folder with no read access does not list, as on a disk of
    /// another user. The package opens: a take recovery and a write fault need the open.
    @Test(arguments: ["Clips", "Transcripts"], [0o000, 0o300] as [mode_t])
    func aFolderThatDoesNotListStillOpens(_ name: String, mode: mode_t) throws {
        let path = url.appending(path: name).path
        try #require(chmod(path, mode) == 0)
        defer { chmod(path, 0o755) }
        try #require(!lists(path))

        let session = try Session(contentsOf: url)

        #expect(Set(session.files.values.map(\.path)) == ["a.wav", "sub/b.wav"])
    }

    /// With search access and no read access, the open of a known path works, so the read checks
    /// each pool file and transcript file that `session.xml` names.
    @Test(arguments: ["Clips/a.wav", "Transcripts/\(PoolItemKindTests.transcriptFile).xml"])
    func aFIFOInAFolderThatDoesNotListIsRefusedAtOnce(_ path: String) async throws {
        let xml = url.appending(path: "session.xml")
        let text = try String(contentsOf: xml, encoding: .utf8).replacing(
            /(<session [^>]*version=")\d+"/, with: { "\($0.1)\(sessionVersion)\"" }
        ).replacingOccurrences(
            of: "</session>",
            with: #"<transcripts><transcript id="1" name="t" file="\#(Self.transcriptFile)"/></transcripts></session>"#)
        try Data(text.utf8).write(to: xml)
        let fifo = url.appending(path: path)
        try makeFIFO(at: fifo)
        let folder = fifo.deletingLastPathComponent().path
        try #require(chmod(folder, 0o300) == 0)
        defer { chmod(folder, 0o755) }
        try #require(!lists(folder))

        let value = await read(waitingOn: fifo)

        #expect(value == .failure(.unsafeItem(path)))
    }

    nonisolated static let transcriptFile = "0F0E0D0C-0B0A-4908-8706-050403020100"

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

    /// The same FIFO in a `Clips/` folder that does not list: the read of the package cannot see
    /// it, so the placement refuses it as no audio, with no wait.
    @Test func aFIFOStemWAVInAFolderThatDoesNotListIsNoAudio() async throws {
        let package = try RawRemovalCrashTests.take()
        let (source, url) = (package.url, package.folder.url.appending(path: "Copy.dirigible"))
        try await offMainActor {
            let outcome = completeTake(of: try Session(contentsOf: source), lock: try PackageLock(source), level: false)
            {
                _ throws(SessionFileError) in
                do { try FileManager.default.copyItem(at: source, to: url) } catch { Issue.record(error) }
                throw .writeFailed(step: "crash", errno: EIO)
            }
            #expect(outcome.error == .file(.writeFailed(step: "crash", errno: EIO)))
        }
        try FileManager.default.removeItem(at: url.appending(path: "Capture/take1-1-1.caf"))
        let fifo = url.appending(path: "Clips/take1-1-1.wav")
        try makeFIFO(at: fifo)
        let clips = url.appending(path: "Clips").path
        try #require(chmod(clips, 0o300) == 0)
        defer { chmod(clips, 0o755) }
        let name = RawRemovalCrashTests.segments[0]

        let value = await valueWithNoWriter(of: fifo) { () -> Result<SegmentFault?, SessionFileError> in
            let session: Session
            do throws(SessionFileError) {
                session = try Session(contentsOf: url)
            } catch {
                return .failure(error)
            }
            guard let recording = session.recording,
                case .failure(let fault) = try? placeSegment(
                    name, to: .aligned(recording, track: "t1"), of: session, in: url)
            else { return .success(nil) }
            return .success(fault)
        }

        #expect(value == .success(.badAudio))
    }
}
