import AudioToolbox
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Progress, cancel, the confirmed replace, the fault map, the package path, and the leftover
/// sweep of `exportMix` (export run criteria 9 to 17).
struct ExportSafetyTests {
    let package: MixPackage
    let url: URL
    let source = ExportSource(range: 0..<96_000)!
    let options = ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .session)

    init() throws {
        package = try ExportTests.package([ExportTests.tone(frames: 96_000)])
        url = package.folder.url.appending(path: "mix.wav")
    }

    /// The `.tmp` files in the folder of the target.
    func temporaryFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.folder.url.path).filter { $0.hasSuffix(".tmp") }
    }

    func export(
        replacing: ConfirmedFile? = nil, chunk: Int = 48_000, progress: (Double) -> Void = { _ in }
    ) throws(ExportError) {
        _ = try exportMix(
            package.session, source: source, options: options, to: url, replacing: replacing,
            package: { package.url }, progress: progress, chunk: chunk)
    }

    /// Checks that `url` holds the 2 s export of the tone.
    func expectTheExport() throws {
        let out = try ExportTests.read(url)
        #expect(out.length == 96_000)
        #expect(abs(ExportTests.rmsDB(out.channels[0]) - -20) <= 0.01)
    }

    @Test func progressGoesUpToOne() throws {
        var values: [Double] = []

        try export(chunk: 480) { values.append($0) }

        #expect(values.count <= 101, "\(values.count) calls")
        #expect(values.count >= 10, "\(values.count) calls")
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 })
        #expect(values.allSatisfy { (0...1).contains($0) })
        #expect(values.last == 1)
    }

    /// The export task cancels itself at the first progress call. The old target stays. The
    /// limit runs from the cancel to the throw, so a late start of the task under load does
    /// not count.
    @Test func aCancelLeavesNoFileAndKeepsTheOldTarget() async throws {
        try Data("old".utf8).write(to: url)
        let confirmed = try #require(ConfirmedFile(at: url))
        let (session, packageURL, url, source, options) = (package.session, package.url, url, source, options)

        let task = Task { () -> (Result<[FileID: MediaFault], ExportError>, Duration?) in
            let clock = ContinuousClock()
            var cancelled: ContinuousClock.Instant?
            let result = Result { () throws(ExportError) in
                try exportMix(
                    session, source: source, options: options, to: url, replacing: confirmed, package: { packageURL },
                    progress: { _ in
                        guard cancelled == nil else { return }
                        cancelled = clock.now
                        withUnsafeCurrentTask { $0?.cancel() }
                    }, chunk: 480)
            }
            return (result, cancelled.map { clock.now - $0 })
        }

        let (result, wait) = await task.value
        #expect(throws: ExportError.cancelled) { try result.get() }
        #expect(try #require(wait) < .seconds(2))
        #expect(try Data(contentsOf: url) == Data("old".utf8))
        #expect(try temporaryFiles() == [])
    }

    /// A cancel at the progress call of 1.0, after the last chunk: the export throws `.cancelled`
    /// before the flush and the move. The old target stays. Code gate 1, item 3.
    @Test func aCancelAfterTheLastChunkLeavesNoFile() throws {
        try Data("old".utf8).write(to: url)
        var cancelled = false

        #expect(throws: ExportError.cancelled) {
            _ = try exportMix(
                package.session, source: source, options: options, to: url, replacing: ConfirmedFile(at: url),
                package: { package.url }, progress: { if $0 == 1 { cancelled = true } }, isCancelled: { cancelled })
        }
        #expect(try Data(contentsOf: url) == Data("old".utf8))
        #expect(try temporaryFiles() == [])
    }

    @Test func anExistingTargetIsKeptWithNoConfirmation() throws {
        try Data("old".utf8).write(to: url)

        #expect(throws: ExportError.exists) { try export() }
        #expect(try Data(contentsOf: url) == Data("old".utf8))
        #expect(try temporaryFiles() == [])
    }

    @Test func aConfirmedTargetIsReplaced() throws {
        try Data("old".utf8).write(to: url)

        try export(replacing: ConfirmedFile(at: url))

        try expectTheExport()
        #expect(try temporaryFiles() == [])
    }

    /// The user confirmed item A. At the progress call of 1.0, a new item B takes its place.
    @Test func anItemThatReplacedTheConfirmedOneIsKept() throws {
        try Data("A".utf8).write(to: url)
        let confirmed = try #require(ConfirmedFile(at: url))
        let url = url

        #expect(throws: ExportError.exists) {
            try export(replacing: confirmed) { fraction in
                guard fraction == 1 else { return }
                unlink(url.path)
                FileManager.default.createFile(atPath: url.path, contents: Data("B".utf8))
            }
        }
        #expect(try Data(contentsOf: url) == Data("B".utf8))
        #expect(try temporaryFiles() == [])
    }

    @Test func aDeletedConfirmedTargetStillLands() throws {
        try Data("A".utf8).write(to: url)
        let confirmed = try #require(ConfirmedFile(at: url))
        let url = url

        try export(replacing: confirmed) { fraction in
            if fraction == 1 { unlink(url.path) }
        }

        try expectTheExport()
        #expect(try temporaryFiles() == [])
    }

    /// -40 from `ExtAudioFileWrite` with errno ENOSPC is a full disk; with EIO it is a lost
    /// volume (probes P8, P8b).
    @Test func writeFaultMapsOnlyENOSPCToDiskFull() {
        #expect(writeFault(status: -40, errno: ENOSPC) == .diskFull)
        #expect(writeFault(status: -40, errno: EIO) == .writeFailed(-40))
        #expect(writeFault(status: -40, errno: 0) == .writeFailed(-40))
        #expect(
            writeFault(status: kAudioFileUnspecifiedError, errno: ENOSPC) == .writeFailed(kAudioFileUnspecifiedError))
    }

    /// The progress call of chunk 1 moves the package. The clip at 96 000 opens after the move.
    @Test func aMoveDuringAnExportReadsTheMovedPackage() throws {
        let package = try MixPackage()
        try package.addFile("f1", channels: [ExportTests.tone(frames: 48_000)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 96_000, offset: 0, length: 48_000)
        let moved = package.folder.url.appending(path: "Moved.dirigible")
        var current = package.url

        _ = try exportMix(
            package.session, source: #require(ExportSource(range: 0..<144_000)), options: options, to: url,
            package: { current },
            progress: { _ in
                guard current == package.url else { return }
                rename(package.url.path, moved.path)
                current = moved
            })

        #expect(current == moved)
        let out = try ExportTests.read(url)
        #expect(abs(ExportTests.rmsDB(Array(out.channels[0][96_000...])) - -20) <= 0.01)
    }

    /// The package source throws at chunk 2: the lock lost the package.
    @Test func aGonePackageFailsTheExport() throws {
        var calls = 0

        #expect(throws: ExportError.packageUnavailable) {
            _ = try exportMix(
                package.session, source: source, options: options, to: url,
                package: { () throws(SessionFileError) -> URL in
                    calls += 1
                    guard calls < 2 else { throw .readFailed(errno: ENOENT) }
                    return package.url
                })
        }
        #expect(calls == 2)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try temporaryFiles() == [])
    }

    @Test func aLeftoverOfADeadExportIsRemoved() throws {
        let folder = package.folder.url
        let dead = ".mix.wav.\(UUID().uuidString).tmp"
        for name in [dead, ".mix.wav.other.tmp"] {
            FileManager.default.createFile(atPath: folder.appending(path: name).path, contents: Data())
        }

        try export()

        #expect(try temporaryFiles() == [".mix.wav.other.tmp"])
        try expectTheExport()
    }
}
