import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// An edit or a prune of an archived package through the CLI and MCP (decision 0072, run criteria
/// C9, C10, and C21 (b) and (d)): the step converts each FLAC back to a WAV first, and a command
/// that writes nothing changes no file.
///
/// Fixture: track `t1` with the clips `A` and `B` on the 24-bit pool files `a.wav` and `b.wav`, and
/// with `unused`, the pool file `u.wav` that no clip uses. The package is archived in the test
/// process, so each pool file is a FLAC and `session.xml` has `archive="flac"`.
struct ArchiveCommandTests {
    let package: TemporaryPackage
    /// A copy of `a.wav` before the archive, outside the package.
    let copyOfA: URL
    var clips: URL { package.url.appending(path: clipsFolderName) }

    init() throws { try self.init(unused: false) }

    init(unused: Bool) throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        package = try TemporaryPackage(session)
        try FileManager.default.createDirectory(
            at: package.url.appending(path: clipsFolderName), withIntermediateDirectories: true)
        let names = unused ? ["a.wav", "b.wav", "u.wav"] : ["a.wav", "b.wav"]
        for (index, name) in names.enumerated() {
            try session.addFile(
                try Self.writeWAV(package.url.appending(path: "\(clipsFolderName)/\(name)"), seed: index))
        }
        try session.place(Clip(id: "A", file: "a.wav", start: 0, offset: 0, length: 30_000), on: "t1")
        try session.place(Clip(id: "B", file: "b.wav", start: 30_000, offset: 0, length: 30_000), on: "t1")
        try session.write(to: package.url)
        copyOfA = package.folder.appending(path: "a-copy.wav")
        try FileManager.default.copyItem(at: package.url.appending(path: "\(clipsFolderName)/a.wav"), to: copyOfA)
        let url = package.url
        _ = try archivePackage(&session, in: url) { session throws(SessionFileError) in
            try session.write(to: url)
            return url
        }
        try #require(try self.names().allSatisfy { $0.hasSuffix(".flac") })
        // The first edit makes the lock file (decision 0012).
        FileManager.default.createFile(atPath: url.appending(path: ".lock").path, contents: nil)
    }

    /// 30,000 frames of mono noise from `seed`, 24-bit through the clip writer. Returns its entry.
    static func writeWAV(_ url: URL, seed: Int) throws -> AudioFile {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 30_000))
        buffer.frameLength = 30_000
        var state = UInt64(seed + 1)
        for frame in 0..<30_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            buffer.floatChannelData![0][frame] = Float(Int32(truncatingIfNeeded: state >> 40) - 8_388_608) / 8_388_608
        }
        let writer = try ClipWriter(url: url, file: url.lastPathComponent, format: format)
        try writer.write(buffer)
        try writer.close()
        return AudioFile(id: FileID(url.lastPathComponent), path: url.lastPathComponent, layout: .mono, length: 30_000)
    }

    func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted() }

    /// Each file of the package by its relative path, with the bytes and the modification time.
    func snapshot() throws -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(atPath: package.url.path)
        while let path = enumerator?.nextObject() as? String {
            let url = package.url.appending(path: path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            let time = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            files[path] = try Data(contentsOf: url) + Data("\(time)".utf8)
        }
        return files
    }

    /// The relative paths that `snapshot()` adds, removes, or changes since `before`, sorted.
    func changes(since before: [String: Data]) throws -> [String] {
        let now = try snapshot()
        return Set(before.keys).union(now.keys).filter { before[$0] != now[$0] }.sorted()
    }

    /// The edit is in the session, each pool file is a WAV, and `session.xml` has no attribute and
    /// the version of its other data.
    func expectUnarchived(marker: Bool = true) throws {
        #expect(try names() == ["a.wav", "b.wav"])
        let xml = String(decoding: try package.xml(), as: UTF8.self)
        #expect(!xml.contains("archive="), Comment(rawValue: xml))
        let version = try #require(try #/version="(\d+)"/#.firstMatch(in: xml)).output.1
        #expect(Int(version)! < archiveSessionVersion)
        if marker { #expect(try package.read().markers.values.map(\.name) == ["Note"]) }
    }

    /// C9. Fail value: the edit writes the archived session and leaves each FLAC.
    @Test func anEditOnAnArchivedPackageUnarchivesFirst() async throws {
        let result = try await package.run("marker", "set", "PKG", "--name", "Note", "--at", "10")

        #expect(result.status == 0, "\(result)")
        #expect(result.stderr.split(separator: "\n").contains { $0.hasPrefix("unarchive: ") }, "\(result)")
        try expectUnarchived()
    }

    /// C9, the stdio MCP server: the same state.
    @Test func aMarkerSetToolOnAnArchivedPackageUnarchivesFirst() async throws {
        let call = toolCall(1, "marker_set", ["package": package.path, "name": "Note", "at": 10])

        let result = toolResult(answer(try await mcp([call]), id: 1))

        #expect(!result.isError, "\(result)")
        try expectUnarchived()
    }

    /// C9 near input: a refused edit and the read commands change no file.
    @Test func aRefusedEditAndTheReadsChangeNoFile() async throws {
        let before = try snapshot()

        #expect(try await package.run("marker", "remove", "PKG", "none").status == 1)
        #expect(try await package.run("info", "PKG").status == 0)
        #expect(try await package.run("peaks", "PKG").status == 0)

        let changed = try changes(since: before)
        #expect(changed == [])
    }

    /// C9: an import opens each pool file in its compare (decision 0040), so it runs after the step
    /// and finds the WAV of `a.wav`. Fail value: a compare with the FLACs adds a new file.
    @Test func anImportOfAPoolFileGivesItsFileAfterTheStep() async throws {
        let result = try await package.run("import", "PKG", copyOfA.path, "--track", "t1", "--at", "90000")

        #expect(result.status == 0, "\(result)")
        #expect(result.stderr.contains("unarchive: "), "\(result)")
        let session = try package.read()
        #expect(Set(session.files.keys) == ["a.wav", "b.wav"])
        #expect(try names() == ["a.wav", "b.wav"])
    }

    /// C10 store case: a package archived while the store was another path, then named as the
    /// store. The store write keeps a backup at each save, and the step keeps none, so the rename
    /// adds one backup with no attribute. Fail value: a step save at the store policy adds a
    /// backup of the archived file.
    @Test func aStoreWriteOnAnArchivedStoreKeepsOneBackupWithNoAttribute() async throws {
        let backups = package.url.appending(path: backupsFolderName)
        try package.edit { _ = try $0.addBin("bin1", named: "Old") }

        let result = try await dirigible(
            ["bin", "rename", package.path, "bin1", "New"], favorites: package.url)

        #expect(result.status == 0, "\(result)")
        let files = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        #expect(files.count == 1, "\(files)")
        for file in files {
            let text = String(decoding: try Data(contentsOf: backups.appending(path: file)), as: UTF8.self)
            #expect(!text.contains("archive=\"flac\""), "\(file)")
        }
        #expect(try names() == ["a.wav", "b.wav"])
    }
}

/// C21 (b) and (d): a prune of an archived package moves WAVs, never a FLAC.
struct ArchivePruneCommandTests {
    let fixture: ArchiveCommandTests
    var package: TemporaryPackage { fixture.package }

    init() throws { fixture = try ArchiveCommandTests(unused: true) }

    /// Removes each Trash URL of the output lines (`<path>\t<bytes>\t<trash URL>`).
    func emptyTrash(_ stdout: String) {
        for line in stdout.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            if fields.count == 3 { try? FileManager.default.removeItem(atPath: String(fields[2])) }
        }
    }

    /// C21 (b). The dry run lists `u.wav` with the bytes of its FLAC and changes no file. The prune
    /// unarchives first and moves the WAV. Fail value: the prune moves the FLAC of a scan made
    /// before the step.
    @Test func aPruneOfAnArchivedPackageMovesTheWAV() async throws {
        let flac = try Data(contentsOf: fixture.clips.appending(path: "u.flac"))
        let before = try fixture.snapshot()

        let listed = try await package.run("file", "prune", "PKG", "--dry-run")

        #expect(listed.stdout.contains("u.wav\t\(flac.count) bytes\n"), "\(listed)")
        let changed = try fixture.changes(since: before)
        #expect(changed == [], "the dry run changes no file")
        #expect(!listed.stderr.contains("unarchive: "))

        let pruned = try await package.run("file", "prune", "PKG")
        defer { emptyTrash(pruned.stdout) }

        #expect(pruned.status == 0, "\(pruned)")
        #expect(pruned.stderr.contains("unarchive: "), "\(pruned)")
        let moved = pruned.stdout.split(separator: "\n").map { $0.split(separator: "\t") }.filter { $0.count == 3 }
        #expect(moved.map { String($0[0]) } == ["u.wav"], "\(pruned)")
        #expect(moved.allSatisfy { $0[2].hasSuffix(".wav") }, "no FLAC goes to the Trash")
        try fixture.expectUnarchived(marker: false)
        #expect(try package.read().files["u.wav"] == nil)
    }

    /// C21 (b) near input: with no unused file, the prune and `file_prune` change no file.
    @Test func aPruneWithNoUnusedFileChangesNoFile() async throws {
        let used = try ArchiveCommandTests()
        let before = try used.snapshot()

        let result = try await used.package.run("file", "prune", "PKG")
        let tool = toolResult(
            answer(try await mcp([toolCall(1, "file_prune", ["package": used.package.path])]), id: 1))

        #expect(result.status == 0 && result.stderr == "", "\(result)")
        #expect(!tool.isError, "\(tool)")
        let changed = try used.changes(since: before)
        #expect(changed == [])
    }

    /// C21 (b), the MCP tool: the same moves.
    @Test func aPruneToolOfAnArchivedPackageMovesTheWAV() async throws {
        let call = toolCall(1, "file_prune", ["package": package.path])

        let result = toolResult(answer(try await mcp([call]), id: 1))
        defer { emptyTrash(result.text) }

        #expect(!result.isError, "\(result)")
        #expect(result.text.hasPrefix("u.wav\t"), "\(result)")
        try fixture.expectUnarchived(marker: false)
    }

    /// C21 (d): `file remove` of the unused entry unarchives first, so the prune finds its WAV as a
    /// stray file and no FLAC stays.
    @Test func aRemovedFileOfAnArchivedPackageIsAStrayWAV() async throws {
        let removed = try await package.run("file", "remove", "PKG", "u.wav")
        let listed = try await package.run("file", "prune", "PKG", "--dry-run")

        #expect(removed.status == 0, "\(removed)")
        #expect(try fixture.names() == ["a.wav", "b.wav", "u.wav"])
        #expect(listed.stdout.hasPrefix("u.wav\t"), "\(listed)")
    }
}
