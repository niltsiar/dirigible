import CryptoKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `dirigible file archive`, `dirigible file unarchive`, and their MCP tools (decision 0072, run
/// criteria C2, C6, C10, C11, C12, C13, and C16).
///
/// Fixture: track `t1` with the clips `A` (cut at frame 10,000, with an envelope) and `B` (with a
/// gain) on the 24-bit pool files `a.wav` and `b.wav`, the pool file `c.wav` that no clip uses, a
/// bin, a chapter marker, two backups, a transcript file, a sidecar, an anchor, a kept CAF, and an
/// artwork file. No file is a clone.
struct FileArchiveCommandTests {
    let package: TemporaryPackage
    var clips: URL { package.url.appending(path: clipsFolderName) }

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        package = try TemporaryPackage(session)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        for (index, name) in ["a.wav", "b.wav", "c.wav"].enumerated() {
            try session.addFile(try ArchiveCommandTests.writeWAV(clips.appending(path: name), seed: index))
        }
        try session.place(Clip(id: "A", file: "a.wav", start: 0, offset: 0, length: 30_000), on: "t1")
        try session.place(Clip(id: "B", file: "b.wav", start: 30_000, offset: 0, length: 30_000), on: "t1")
        _ = try session.split("A", at: 10_000)
        try session.setEnvelope([Frames(5_000): try #require(Gain(dB: -6))], clip: "A")
        try session.setGain(try #require(Gain(dB: -3)), clip: "B")
        try session.setMarker(Marker(id: "m", name: "Intro", position: 1_000, kind: .chapter))
        _ = try session.addBin("bin1", named: "Keep")
        try session.write(to: package.url)
        let xml = try package.xml()
        for (path, data) in [
            "\(backupsFolderName)/session-20260101T000000.000Z.xml": xml,
            "\(backupsFolderName)/session-20260102T000000.000Z.xml": xml,
            "Transcripts/words.json": Data("{}".utf8),
            "\(captureFolderName)/take2-1-1.sidecar": Data("a sidecar".utf8),
            "\(captureFolderName)/take2.anchor": Data("an anchor".utf8),
            "\(captureFolderName)/take2-1-1.caf": Data("a kept CAF".utf8),
            "Artwork/cover.png": Data("a cover".utf8),
        ] {
            let url = package.url.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        // The first command makes the lock file (decision 0012).
        FileManager.default.createFile(atPath: package.url.appending(path: ".lock").path, contents: nil)
    }

    func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted() }

    /// The SHA-256 of each file in the folders that the jobs never change, by relative path.
    func otherFiles() throws -> [String: String] {
        var hashes: [String: String] = [:]
        for folder in [backupsFolderName, "Transcripts", captureFolderName, "Artwork"] {
            for name in try FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: folder).path) {
                let data = try Data(contentsOf: package.url.appending(path: "\(folder)/\(name)"))
                hashes["\(folder)/\(name)"] = SHA256.hash(data: data).description
            }
        }
        return hashes
    }

    /// C2. Fail value: `file archive` is no command.
    @Test func anArchiveRoundTripKeepsThePackage() async throws {
        let (xml, others) = (try package.xml(), try otherFiles())
        let info = try await package.run("info", "PKG", "--json")

        let archived = try await package.run("file", "archive", "PKG")

        #expect(archived.status == 0, "\(archived)")
        #expect(try names() == ["a.flac", "b.flac", "c.flac"])
        let unarchived = try await package.run("file", "unarchive", "PKG")

        #expect(unarchived.status == 0, "\(unarchived)")
        #expect(try names() == ["a.wav", "b.wav", "c.wav"])
        #expect(try package.xml() == xml)
        #expect(try otherFiles() == others)
        let infoAfter = try await package.run("info", "PKG", "--json")
        #expect(infoAfter.stdout == info.stdout && info.status == 0)
    }

    /// C12 and C13: the bytes line of a package with no clone, and the `archive:` line of `info`.
    @Test func anArchiveGivesItsBytesAndInfoGivesItsState() async throws {
        let result = try await package.run("file", "archive", "PKG")

        #expect(result.status == 0, "\(result)")
        let line = try #require(
            result.stdout.firstMatch(of: #/Freed: (\d+) bytes\. Written: (\d+) bytes\. Net: (-?\d+) bytes\./#))
        let (freed, written, net) = (Int(line.output.1)!, Int(line.output.2)!, Int(line.output.3)!)
        #expect(freed > written && written > 0 && net == freed - written, "\(result)")
        #expect(result.stdout.contains("An APFS snapshot of the volume can keep these bytes in use"), "\(result)")
        #expect(!result.stdout.contains("The archive freed no disk space"))
        let info = try await package.run("info", "PKG")
        #expect(info.stdout.contains("archive: flac, 3 files in FLAC, 0 kept\n"), "\(info)")
        let json = try await package.run("info", "PKG", "--json")
        #expect(json.stdout.contains(#""archive""#), "\(json)")
    }

    /// C12: each WAV is a clone of a file outside the package, so the unlinks free no byte.
    @Test func anArchiveOfClonesFreesNoSpace() async throws {
        for name in ["a.wav", "b.wav", "c.wav"] {
            let (wav, copy) = (clips.appending(path: name), package.folder.appending(path: name))
            try FileManager.default.copyItem(at: wav, to: copy)
            try FileManager.default.removeItem(at: wav)
            try #require(copyfile(copy.path, wav.path, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE)) == 0)
        }

        let result = try await package.run("file", "archive", "PKG")

        #expect(result.status == 0, "\(result)")
        #expect(result.stdout.contains("Freed: 0 bytes."), "\(result)")
        #expect(
            result.stdout.contains("The archive freed no disk space: the WAV files share their data with a copy."),
            "\(result)")
        #expect(!result.stdout.contains("APFS snapshot"))
    }

    /// C6, the MCP tools: `file_archive`, then `file_unarchive`; `info` then has no `archive:` line.
    @Test func theArchiveToolsGiveTheSameState() async throws {
        let archived = toolResult(
            answer(try await mcp([toolCall(1, "file_archive", ["package": package.path])]), id: 1))

        #expect(!archived.isError, "\(archived)")
        #expect(try names() == ["a.flac", "b.flac", "c.flac"])
        #expect(String(decoding: try package.xml(), as: UTF8.self).contains(#"archive="flac""#))
        let unarchived = toolResult(
            answer(try await mcp([toolCall(1, "file_unarchive", ["package": package.path])]), id: 1))

        #expect(!unarchived.isError, "\(unarchived)")
        #expect(try names() == ["a.wav", "b.wav", "c.wav"])
        let info = try await package.run("info", "PKG")
        #expect(!info.stdout.contains("archive:"), "\(info)")
    }

    /// C16: a pending take refuses the archive. Fail value: the archive converts the files.
    @Test func anArchiveOfAPendingTakeChangesNoFile() async throws {
        try package.edit {
            try $0.setRecording(Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: ["t1"]))
        }
        let before = try snapshot(of: package)

        let result = try await package.run("file", "archive", "PKG")

        #expect(result.status == 2, "\(result)")
        #expect(result.stderr.contains(pendingTakeMessage(package.path)), "\(result)")
        #expect(try changes(of: package, since: before) == [])
    }

    /// C16: a pending take refuses the unarchive too, as in the app, so no job saves session.xml
    /// while it holds `<recording>`. Fail value: the unarchive converts the files and saves.
    @Test func anUnarchiveOfAPendingTakeChangesNoFile() async throws {
        #expect(try await package.run("file", "archive", "PKG").status == 0)
        try package.edit {
            try $0.setRecording(Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: ["t1"]))
        }
        let before = try snapshot(of: package)

        let result = try await package.run("file", "unarchive", "PKG")

        try #require(result.status == 2, "\(result)")
        #expect(result.stderr.contains(pendingTakeMessage(package.path)), "\(result)")
        #expect(try changes(of: package, since: before) == [])
    }

    /// C16, the store: the Favorites store path, and a link to it, refuse the archive; the help says
    /// so. Near input: the same package archives when the store is another path.
    @Test func theFavoritesStoreIsNeverArchived() async throws {
        let link = package.folder.appending(path: "Link.dirigible")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: package.url)
        let before = try snapshot(of: package)
        let text = "The Favorites store is never archived."

        for path in [package.path, link.path] {
            let result = try await dirigible(["file", "archive", path], favorites: package.url)
            #expect(result.status == 2 && result.stderr.contains(text), "\(result)")
        }
        let tool = toolResult(
            answer(
                try await mcp([toolCall(1, "file_archive", ["package": link.path])], favorites: package.url), id: 1))
        #expect(tool.isError && tool.text.contains(text), "\(tool)")
        #expect(try changes(of: package, since: before) == [])
        let help = try await dirigible("file", "archive", "--help")
        // The help wraps its lines.
        #expect(help.stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ").contains(text), "\(help)")
        #expect(AgentManual.skill.contains(AgentManual.archiveLine) && AgentManual.archiveLine.contains(text))
        #expect(AgentManual.skill.contains("| file_unarchive | dirigible file unarchive |"))

        let other = try await package.run("file", "archive", "PKG")
        #expect(other.status == 0, "\(other)")
    }

    /// C11 CLI text: the disk refusal names the need and the free bytes. The CLI exits 2 for each
    /// `ArchiveFault`, as the pending-take case shows.
    @Test func theDiskRefusalNamesBothNumbers() {
        let fault = ArchiveFault.space(need: 2_158_377_692, free: 2_158_377_691)

        #expect(fault.message(package: "Show.dirigible").contains("2158377692"))
        #expect(fault.message(package: "Show.dirigible").contains("2158377691"))
    }
}

/// C6 and C10 on an archived package: the near inputs, the repairs, and a damaged FLAC.
struct FileUnarchiveCommandTests {
    let fixture: ArchiveCommandTests
    var package: TemporaryPackage { fixture.package }

    init() throws { fixture = try ArchiveCommandTests() }

    /// C6 near inputs: an archive of an archived package, and an unarchive of a working package,
    /// change no file.
    @Test func aJobWithNothingToConvertChangesNoFile() async throws {
        let before = try fixture.snapshot()

        let archived = try await package.run("file", "archive", "PKG")

        #expect(archived.status == 0, "\(archived)")
        #expect(try fixture.changes(since: before) == [])
        let unarchived = try await package.run("file", "unarchive", "PKG")
        #expect(unarchived.status == 0, "\(unarchived)")
        let working = try fixture.snapshot()

        let again = try await package.run("file", "unarchive", "PKG")

        #expect(again.status == 0 && again.stderr == "", "\(again)")
        #expect(try fixture.changes(since: working) == [])
    }

    /// C6 repair: no attribute and every pool file a FLAC; then the attribute and every pool file a WAV.
    @Test func anUnarchiveRepairsAMixedState() async throws {
        try package.edit { $0.archive = nil }

        let result = try await package.run("file", "unarchive", "PKG")

        #expect(result.status == 0, "\(result)")
        try fixture.expectUnarchived(marker: false)
        try package.edit { $0.archive = .flac }

        let again = try await package.run("file", "unarchive", "PKG")

        #expect(again.status == 0, "\(again)")
        try fixture.expectUnarchived(marker: false)
    }

    /// C10 CLI part: a FLAC cut to half its bytes stays, with one line, exit 1, and a tool error;
    /// the whole FLAC converts. Fail value: exit 0 with no line.
    @Test func aDamagedFLACStaysWithOneLine() async throws {
        let flac = fixture.clips.appending(path: "b.flac")
        let data = try Data(contentsOf: flac)
        try data.prefix(data.count / 2).write(to: flac)

        let result = try await package.run("file", "unarchive", "PKG")

        #expect(result.status == 1, "\(result)")
        let lines = result.stderr.split(separator: "\n").filter { $0.contains("damaged, kept as FLAC: ") }
        #expect(lines.count == 1, "\(result)")
        #expect(
            lines.first?.contains("Clips/b.flac, ") == true
                && lines.first?.hasSuffix(" of 30000 frames decoded") == true)
        #expect(try fixture.names() == ["a.wav", "b.flac"])
        #expect(!String(decoding: try package.xml(), as: UTF8.self).contains("archive="))

        let tool = toolResult(
            answer(try await mcp([toolCall(1, "file_unarchive", ["package": package.path])]), id: 1))
        #expect(tool.isError && tool.text.contains("damaged, kept as FLAC: Clips/b.flac, "), "\(tool)")
    }

    /// C18 `EXPORT miss`: an export and a silence read unarchive first, then read the WAVs. Fail
    /// value: the reads open the FLACs, and the package stays archived.
    @Test func anExportAndAReadOfAnArchivedPackageUnarchiveFirst() async throws {
        let out = package.folder.appending(path: "mix.wav")

        let exported = try await package.run("export", "PKG", "--out", out.path)

        #expect(exported.status == 0, "\(exported)")
        #expect(exported.stderr.contains("unarchive: "), "\(exported)")
        #expect(FileManager.default.fileExists(atPath: out.path))
        try fixture.expectUnarchived(marker: false)
        let read = try await package.run("silences", "PKG")
        #expect(read.status == 0 && !read.stderr.contains("unarchive: "), "\(read)")
    }

    /// C18, the MCP tool: `silences` on an archived package unarchives first.
    @Test func aSilencesToolOfAnArchivedPackageUnarchivesFirst() async throws {
        let result = toolResult(answer(try await mcp([toolCall(1, "silences", ["package": package.path])]), id: 1))

        #expect(!result.isError, "\(result)")
        try fixture.expectUnarchived(marker: false)
    }

    /// C21 (d): a revert to a backup with no entry for `u.wav` unarchives first, so the prune
    /// finds its WAV as a stray file, no FLAC stays, and no backup holds the archived file.
    @Test func aRevertOfAnArchivedPackageLeavesAStrayWAV() async throws {
        let unused = try ArchiveCommandTests(unused: true)
        var older = try unused.package.read()
        try older.removeFile("u.wav")
        older.archive = nil
        let copy = unused.package.folder.appending(path: "Older.dirigible")
        try older.write(to: copy)
        let backups = unused.package.url.appending(path: backupsFolderName)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let name = "session-20260101T000000.000Z.xml"
        try FileManager.default.copyItem(at: copy.appending(path: "session.xml"), to: backups.appending(path: name))

        let reverted = try await unused.package.run("backup", "revert", "PKG", "--name", name)
        let listed = try await unused.package.run("file", "prune", "PKG", "--dry-run")

        #expect(reverted.status == 0, "\(reverted)")
        #expect(try unused.names() == ["a.wav", "b.wav", "u.wav"])
        #expect(listed.stdout.hasPrefix("u.wav\t"), "\(listed)")
        for file in try FileManager.default.contentsOfDirectory(atPath: backups.path) {
            let text = String(decoding: try Data(contentsOf: backups.appending(path: file)), as: UTF8.self)
            #expect(!text.contains(#"archive="flac""#), "\(file)")
        }
    }
}

/// Each regular file of `package` by its relative path, with its bytes and its modification time.
private func snapshot(of package: TemporaryPackage) throws -> [String: Data] {
    var files: [String: Data] = [:]
    let enumerator = FileManager.default.enumerator(atPath: package.url.path)
    while let path = enumerator?.nextObject() as? String {
        let url = package.url.appending(path: path)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        guard values.isRegularFile == true else { continue }
        files[path] =
            try Data(contentsOf: url) + Data("\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)".utf8)
    }
    return files
}

private func changes(of package: TemporaryPackage, since before: [String: Data]) throws -> [String] {
    let now = try snapshot(of: package)
    return Set(before.keys).union(now.keys).filter { before[$0] != now[$0] }.sorted()
}
