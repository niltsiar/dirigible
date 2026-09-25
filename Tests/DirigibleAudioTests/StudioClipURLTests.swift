import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Edit-commands criterion 23: `Studio.clipURLs` gives the pool files that exist, under the path
/// that the lock holds now (decision 0014). It reads the disk off the main actor.
@MainActor struct StudioClipURLTests {
    let folder: TemporaryFolder
    let url: URL

    /// The pool files f1 and f2; only `Clips/f1.wav` is on disk. The init runs before the test
    /// on the main actor, but these are two small writes.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 48_000))
        try session.addFile(AudioFile(id: "f2", path: "f2.wav", layout: .mono, length: 48_000))
        try session.write(to: url)
        try FileManager.default.createDirectory(
            at: url.appending(path: clipsFolderName), withIntermediateDirectories: true)
        try Data([0]).write(to: url.appending(path: "\(clipsFolderName)/f1.wav"))
    }

    /// The package is renamed after the open, and no write has told the studio. The read traps on
    /// the main actor (`dispatchPrecondition`). Controls: the URL of the open gives the old path;
    /// no existence filter gives f2 too.
    @Test func clipURLsReadsTheLockPathOffTheMainActor() async throws {
        let studio = try await Studio.open(url)
        let moved = folder.url.appending(path: "Moved.dirigible")
        try #require(rename(url.path, moved.path) == 0)

        let urls = await studio.clipURLs(["f1", "f2", "gone"])

        #expect(
            urls.map { $0.resolvingSymlinksInPath().path } == [
                moved.appending(path: "\(clipsFolderName)/f1.wav").resolvingSymlinksInPath().path
            ])
        #expect(studio.url.resolvingSymlinksInPath() == url.resolvingSymlinksInPath())
    }
}
