import Foundation
import Testing

@testable import DirigibleCore

/// Decision 0047 Order: the prune saves, then moves the files to the Trash (criteria C8, C9, and
/// C9b). The fake trash returns a made-up Trash URL and moves nothing; a failure throws the error
/// that `trashItem` gave in the U2 probe (NSCocoaErrorDomain 513, the probe sandbox). A FAT volume
/// did not fail: macOS made `.Trashes` on it.
extension UnusedFilesTests {
    static let refusal = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)

    func save(_ session: Session) throws(SessionFileError) -> URL {
        try session.write(to: package)
        return package
    }

    static func fakeTrashURL(_ url: URL) -> URL { URL(filePath: "/Trash").appending(path: url.lastPathComponent) }

    /// C8. The fake trash reads `session.xml` at its first call.
    @Test func savesBeforeTrash() throws {
        var session = try Self.session([("u", "u.wav")])
        try plant("u.wav")
        let scan = try scan(session)
        var onDiskAtTrash: [FileID: AudioFile]?

        let report = try scan.prune(&session, save: save) { url in
            if onDiskAtTrash == nil { onDiskAtTrash = try Session(contentsOf: package).files }
            return Self.fakeTrashURL(url)
        }

        #expect(report.moved.map(\.trashURL) == [URL(filePath: "/Trash/u.wav")], "the trash ran once")
        #expect(onDiskAtTrash?.isEmpty == true, "the pool entry left session.xml before the move")
        #expect(session.files["u"] == nil)
    }

    /// C8 negative. A failed save moves no file and changes no session.
    @Test func saveFailureMovesNothing() throws {
        var session = try Self.session([("u", "u.wav")])
        let before = session
        try plant("u.wav")
        let scan = try scan(session)
        var calls = 0

        #expect(throws: UnusedFilesError.save(.writeFailed(step: "write", errno: ENOSPC))) {
            try scan.prune(
                &session, save: { _ throws(SessionFileError) in throw .writeFailed(step: "write", errno: ENOSPC) },
                trash: { url in
                    calls += 1
                    return Self.fakeTrashURL(url)
                })
        }

        #expect(calls == 0)
        #expect(session == before)
        #expect(FileManager.default.fileExists(atPath: clips.appending(path: "u.wav").path))
    }

    /// C9. A file that does not move stays and the report names it; the other file still moves.
    @Test func trashFailureKeepsFile() throws {
        var session = try Self.session([("a", "a.wav")])
        try plant("a.wav")
        try plant("b.wav")
        let scan = try scan(session)

        let report = try scan.prune(&session, save: save) { url in
            if url.lastPathComponent == "a.wav" { throw Self.refusal }
            return Self.fakeTrashURL(url)
        }

        #expect(report.moved.map(\.item.path) == ["b.wav"])
        #expect(report.failed.map(\.item.path) == ["a.wav"])
        #expect(
            report.failed.first?.fault == TrashFault(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        #expect(FileManager.default.fileExists(atPath: clips.appending(path: "a.wav").path))
        #expect(session.files["a"] == nil, "the entry goes, so the next scan lists a.wav as a stray")
    }

    /// C9b. An unused pool entry with no file loses its entry and is not a failure.
    @Test func missingFileDropsEntry() throws {
        var session = try Self.session([("m", "m.wav")])
        try plant("x.wav")
        let scan = try scan(session)
        try #require(scan.items.map(\.kind) == [.pool("m"), .stray])

        let report = try scan.prune(&session, save: save) { url in Self.fakeTrashURL(url) }

        #expect(report.dropped == ["m"])
        #expect(report.moved.map(\.item.path) == ["x.wav"])
        #expect(report.failed.isEmpty)
        #expect(session.files["m"] == nil)
    }

    /// C12: an item of the first scan that the new scan does not list does not move.
    @Test func intersectionKeepsTheCommonItems() throws {
        let first = try scan(Self.session([("a", "a.wav"), ("b", "b.wav")]))
        try plant("a.wav")
        try plant("b.wav")
        let withFiles = try scan(Self.session([("a", "a.wav"), ("b", "b.wav")]))
        let second = try scan(Self.session([("a", "a.wav"), ("b", "b.wav")], used: ["b"]))

        #expect(Self.paths(withFiles.intersection(second)) == ["a.wav"])
        #expect(first.intersection(withFiles).items.isEmpty, "a file that appeared is another item")
    }
}
