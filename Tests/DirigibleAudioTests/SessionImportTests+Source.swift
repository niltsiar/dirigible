import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The hostile sources of the session import (C7g FIFO, C7h, C7i, C17, C18): the import reads the
/// source only through `Session(contentsOf:)` and the link check, and writes nothing there.
extension SessionImportTests {
    /// Each item under `url` with its kind, size, modification time, and bytes.
    func snapshot(_ url: URL) -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: url.path)
        var lines: [String] = []
        while let path = enumerator?.nextObject() as? String {
            let item = url.appending(path: path).path
            var info = stat()
            lstat(item, &info)
            let bytes = info.st_mode & S_IFMT == S_IFREG ? FileManager.default.contents(atPath: item) : nil
            lines.append(
                "\(path) \(info.st_mode) \(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec) "
                    + (bytes?.base64EncodedString() ?? "-"))
        }
        return lines.sorted()
    }

    /// The new track count or the error of an import of `source` on its own thread, so a FIFO wait
    /// fails the test after 10 s.
    @MainActor
    func importWithNoWriter(_ source: URL, fifo: URL) async -> Result<Int, SessionImportError>? {
        let (session, package) = (target.session, target.url)
        return await valueWithNoWriter(of: fifo) {
            Result { () throws(SessionImportError) in
                try importSession(
                    from: source, into: session, in: package, identity: PackageID(lockFileOf: package), at: 0,
                    markers: false, freeBytes: { .max }
                ).tracks.count
            }
        }
    }

    /// C7g: a named FIFO, a link to a FIFO, and a path out of `Clips/` are refused at the read.
    @MainActor @Test func aNamedSpecialFileIsRefusedAtTheRead() async throws {
        let fifo = try plainSource()
        let a = fifo.url.appending(path: "Clips/a.wav")
        try makeFIFO(at: a)
        let before = try names(target)
        #expect(await importWithNoWriter(fifo.url, fifo: a) == .failure(.source(.unsafeItem("Clips/a.wav"))))

        let linked = try plainSource()
        let outside = target.folder.url.appending(path: "outside.wav")
        try makeFIFO(at: outside)
        let b = linked.url.appending(path: "Clips/a.wav")
        try FileManager.default.removeItem(at: b)
        try FileManager.default.createSymbolicLink(at: b, withDestinationURL: outside)
        #expect(await importWithNoWriter(linked.url, fifo: outside) == .failure(.source(.unsafeItem("Clips/a.wav"))))
        #expect(try names(target) == before)

        let escape = try plainSource()
        let xml = escape.url.appending(path: "session.xml")
        try String(contentsOf: xml, encoding: .utf8).replacing(#"path="a.wav""#, with: #"path="../x.wav""#).write(
            to: xml, atomically: true, encoding: .utf8)
        try expectRefusal(.source(.invalidSession(.invalidPath("../x.wav")))) { () throws(SessionImportError) in
            try run(escape.url)
        }
    }

    /// C7h: the items that the open refuses, and an unreadable named WAV.
    @MainActor @Test func aLinkedSourceItemIsRefusedAtTheRead() async throws {
        let outside = target.folder.url.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        for item in ["Clips", "session.xml", ".lock"] {
            let source = try plainSource()
            let url = source.url.appending(path: item)
            let moved = outside.appending(path: "\(item)-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: url, to: moved)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: moved)
            try expectRefusal(.source(.unsafeItem(item))) { () throws(SessionImportError) in try run(source.url) }
        }

        let hard = try plainSource()
        let lock = hard.url.appending(path: ".lock")
        try FileManager.default.removeItem(at: lock)
        let other = outside.appending(path: "other-lock")
        FileManager.default.createFile(atPath: other.path, contents: nil)
        try #require(link(other.path, lock.path) == 0)
        try expectRefusal(.source(.unsafeItem(".lock"))) { () throws(SessionImportError) in try run(hard.url) }

        let piped = try plainSource()
        let pipe = piped.url.appending(path: ".lock")
        try makeFIFO(at: pipe)
        #expect(await importWithNoWriter(piped.url, fifo: pipe) == .failure(.source(.unsafeItem(".lock"))))

        let pointing = try plainSource()
        let pointer = pointing.url.appending(path: ".lock")
        try FileManager.default.removeItem(at: pointer)
        try FileManager.default.createSymbolicLink(at: pointer, withDestinationURL: target.url.appending(path: ".lock"))
        try expectRefusal(.source(.unsafeItem(".lock"))) { () throws(SessionImportError) in try run(pointing.url) }

        let closed = try plainSource()
        let capture = closed.url.appending(path: "Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        chmod(capture.path, 0o000)
        defer { chmod(capture.path, 0o755) }
        try expectRefusal(.source(.unreadableItem("Capture", errno: EACCES))) { () throws(SessionImportError) in
            try run(closed.url)
        }

        let locked = try plainSource()
        let wav = locked.url.appending(path: "Clips/a.wav")
        chmod(wav.path, 0o000)
        defer { chmod(wav.path, 0o644) }
        try expectRefusal(.source(.unreadableItem("Clips/a.wav", errno: EACCES))) { () throws(SessionImportError) in
            try run(locked.url)
        }
    }

    /// C7i: `session.xml` bytes that the XML guard refuses.
    @Test func aSourceXMLThatTheGuardRefusesIsRefused() throws {
        let nested = String(repeating: "<a>", count: 64) + String(repeating: "</a>", count: 64)
        let edits: [(String) -> String] = [
            { $0.replacing("?>", with: "?>\n<!DOCTYPE session []>", maxReplacements: 1) },
            { $0.replacing(#"encoding="UTF-8""#, with: #"encoding="UTF-16""#) },
            { $0.replacing("</session>", with: nested + "</session>") },
        ]
        for edit in edits {
            let source = try plainSource()
            let xml = source.url.appending(path: "session.xml")
            try edit(try String(contentsOf: xml, encoding: .utf8)).write(to: xml, atomically: true, encoding: .utf8)
            try expectRefusal(.source(.malformedXML)) { () throws(SessionImportError) in try run(source.url) }
        }
        let near = try plainSource()
        let xml = near.url.appending(path: "session.xml")
        let text = try String(contentsOf: xml, encoding: .utf8)
        #expect(text.contains(#"encoding="UTF-8""#))
        try text.replacing(#"encoding="UTF-8""#, with: #"encoding="utf-8""#).write(
            to: xml, atomically: true, encoding: .utf8)
        #expect(try run(near.url).tracks.count == 1)
    }

    /// C17: an import and a refusal leave each source item and byte as it was, and make no `.lock`.
    @Test func theSourcePackageIsNeverWritten() throws {
        let source = try plainSource()
        let before = snapshot(source.url)

        _ = try run(source.url, markers: true)
        #expect(throws: SessionImportError.nothingToImport) { try run(source.url, at: -1 << 30) }

        #expect(snapshot(source.url) == before)
        try FileManager.default.removeItem(at: source.url.appending(path: ".lock"))
        _ = try run(source.url)
        #expect(!FileManager.default.fileExists(atPath: source.url.appending(path: ".lock").path))
    }

    /// C18: a source `Clips/` with search access only imports; a FIFO there is still refused at the read.
    @MainActor @Test func aSourceClipsFolderThatDoesNotListImports() async throws {
        let source = try plainSource()
        let clipsFolder = source.url.appending(path: clipsFolderName)
        let bytes = FileManager.default.contents(atPath: clipsFolder.appending(path: "a.wav").path)
        chmod(clipsFolder.path, 0o100)
        defer { chmod(clipsFolder.path, 0o755) }

        let result = try run(source.url)

        let path = try #require(result.session.files.values.first?.path)
        #expect(FileManager.default.contents(atPath: target.url.appending(path: "Clips/\(path)").path) == bytes)

        let fifo = try plainSource()
        let fifoClips = fifo.url.appending(path: clipsFolderName)
        let a = fifoClips.appending(path: "a.wav")
        try makeFIFO(at: a)
        chmod(fifoClips.path, 0o100)
        defer { chmod(fifoClips.path, 0o755) }
        #expect(await importWithNoWriter(fifo.url, fifo: a) == .failure(.source(.unsafeItem("Clips/a.wav"))))
    }
}
