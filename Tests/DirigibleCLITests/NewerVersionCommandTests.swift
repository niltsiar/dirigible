import DirigibleCore
import Foundation
import Testing

/// Decision 0024 P3 and P4 (criteria 3 and 5): a command on a package whose `session.xml` is
/// version 6 exits 2 with a newer-version message and changes no file of the package. The only
/// permitted new file is an empty `.lock`.
struct NewerVersionCommandTests {
    let package: TemporaryPackage
    var cache: String { package.folder.appending(path: "cache").path }

    static let commands: [[String]] = [
        ["info", "PKG"], ["info", "PKG", "--json"], ["peaks", "PKG", "--cache", "CACHE"],
        ["track", "add", "PKG", "--id", "t2", "--name", "B", "--layout", "mono"], ["take", "finalize", "PKG"],
        ["take", "finalize", "PKG", "--leave-unreadable"],
        ["capture", "place", "PKG", "take1-1-1", "--track", "t1", "--at", "0"],
    ]

    /// Track `t1`, a pending take 1, a leftover temporary file of a save, and a file in each
    /// folder. `session.xml` says version 6.
    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRecording(Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 0, armedTracks: ["t1"]))
        package = try TemporaryPackage(session)
        let xml = String(decoding: try package.xml(), as: UTF8.self)
        try #require(xml.contains("version=\"1\""))
        try Data(xml.replacingOccurrences(of: "version=\"1\"", with: "version=\"6\"").utf8).write(
            to: package.sessionXML)
        try Data("a save of the newer build".utf8).write(
            to: package.url.appending(path: ".session.xml.11111111-2222-3333-4444-555555555555.tmp"))
        for folder in ["Capture", "Clips"] {
            try FileManager.default.createDirectory(
                at: package.url.appending(path: folder), withIntermediateDirectories: true)
        }
        try Data("audio".utf8).write(to: package.url.appending(path: "Capture/take1-1-1.caf"))
        try Data("audio".utf8).write(to: package.url.appending(path: "Clips/take0.wav"))
    }

    func run(_ command: [String]) async throws -> CLIResult {
        try await package.run(command.map { $0 == "CACHE" ? cache : $0 })
    }

    var newer: String {
        "Error: \(package.path)/session.xml was made by a newer version of Dirigible (session version 6). This build "
            + "reads version 5 or lower.\n"
    }

    @Test(arguments: commands)
    func aCommandLeavesANewerPackageUnchanged(command: [String]) async throws {
        FileManager.default.createFile(atPath: package.url.appending(path: ".lock").path, contents: nil)
        let before = try packageFiles(package.url)
        try #require(before.keys.contains(".session.xml.11111111-2222-3333-4444-555555555555.tmp"))

        #expect(try await run(command) == CLIResult(status: 2, stdout: "", stderr: newer))

        #expect(try packageFiles(package.url) == before)
    }

    /// With no `.lock`, a command that takes the lock leaves an empty one, and nothing else.
    @Test(arguments: commands)
    func aCommandAddsAtMostAnEmptyLock(command: [String]) async throws {
        let before = try packageFiles(package.url)
        try #require(before[".lock"] == nil)

        #expect(try await run(command) == CLIResult(status: 2, stdout: "", stderr: newer))

        var after = try packageFiles(package.url)
        #expect(after.removeValue(forKey: ".lock") ?? Data() == Data())
        #expect(after == before)
    }

    /// Criterion 5: a version 1 package keeps the files that it does not know after an edit.
    @Test func anEditKeepsUnknownFiles() async throws {
        let xml = String(decoding: try package.xml(), as: UTF8.self)
        try Data(xml.replacingOccurrences(of: "version=\"6\"", with: "version=\"1\"").utf8).write(
            to: package.sessionXML)
        try package.edit { try $0.setRecording(nil) }
        let unknown = ["future.bin", "Capture/take9-1-1.future"]
        for (index, name) in unknown.enumerated() {
            try Data("newer \(index)".utf8).write(to: package.url.appending(path: name))
        }
        let before = try packageFiles(package.url)

        #expect(
            try await package.run("track", "add", "PKG", "--id", "t2", "--name", "B", "--layout", "mono").status == 0)

        let after = try packageFiles(package.url)
        for name in unknown { #expect(after[name] == before[name], "\(name)") }
        #expect(after["session.xml"] != before["session.xml"], "control: the edit was saved")
    }
}

/// The bytes of each file in `package`, by package-relative path. A folder has empty bytes and
/// a path that ends with "/".
func packageFiles(_ package: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    for path in try FileManager.default.subpathsOfDirectory(atPath: package.path) {
        var folder: ObjCBool = false
        FileManager.default.fileExists(atPath: package.appending(path: path).path, isDirectory: &folder)
        if folder.boolValue {
            files[path + "/"] = Data()
        } else {
            files[path] = try Data(contentsOf: package.appending(path: path))
        }
    }
    return files
}
