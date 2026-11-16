import DirigibleCore
import Foundation
import Testing

/// The commands refuse a package from another person that breaks a rule of the package format
/// (decision 0003), with exit 2 and no output of its content.
struct PackageRefusalCommandTests {
    /// C3. An external entity in `session.xml` names a canary
    /// file. `episode show` exits 2 with the text of a damaged file, and prints no canary text.
    @Test func anExternalEntityPackageIsRefused() async throws {
        let package = try TemporaryPackage()
        let canary = package.folder.appending(path: "canary.txt")
        try Data("canary text of PackageRefusalCommandTests".utf8).write(to: canary)
        try FileManager.default.createDirectory(
            at: package.url.appending(path: "Clips"), withIntermediateDirectories: true)
        let xml = """
            <?xml version="1.0"?>
            <!DOCTYPE session [<!ENTITY x SYSTEM "\(canary.absoluteString)">]>
            <session xmlns="https://github.com/niltsiar/dirigible/session" version="12" sampleRate="48000">\
            <episode><notes>A&x;B</notes></episode></session>

            """
        try Data(xml.utf8).write(to: package.sessionXML)

        let result = try await package.run("episode", "show", "PKG")

        #expect(
            result
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: \(package.path)/session.xml is not a Dirigible session file.\n"))
    }

    /// C9. The `.lock` of `Show.dirigible` is a link to the
    /// `.lock` of `Other.dirigible`. An edit of Show exits 2 and changes neither session file.
    @Test func aLockLinkIsRefused() async throws {
        let package = try TemporaryPackage()
        let other = package.folder.appending(path: "Other.dirigible")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: package.url, withIntermediateDirectories: false)
        try Data().write(to: other.appending(path: ".lock"))
        let otherXML = Data("<other session/>\n".utf8)
        try otherXML.write(to: other.appending(path: "session.xml"))
        let showXML = Data(
            ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                + "<session xmlns=\"https://github.com/niltsiar/dirigible/session\" version=\"12\" sampleRate=\"48000\">\n"
                + "  <files>\n    \n  </files>\n</session>\n").utf8)
        try showXML.write(to: package.sessionXML)
        try FileManager.default.createSymbolicLink(
            atPath: package.url.appending(path: ".lock").path, withDestinationPath: "../Other.dirigible/.lock")

        let result = try await package.run("marker", "set", "PKG", "--name", "X", "--at", "0")

        #expect(result == CLIResult(status: 2, stdout: "", stderr: unsafeLockText(package)))
        #expect(try Data(contentsOf: other.appending(path: "session.xml")) == otherXML)
        #expect(try package.xml() == showXML)
    }

    /// C11. A FIFO `.lock` waits for a writer at a plain open, and `flock` gives ENOTSUP on it, which
    /// opens a package unlocked. The edit must end at once with the refusal, not with a success.
    @Test func aFIFOLockIsRefusedAtOnce() async throws {
        let package = try TemporaryPackage(Session(sampleRate: 48_000))
        try #require(mkfifo(package.url.appending(path: ".lock").path, 0o644) == 0)
        let xml = try package.xml()

        let result = try await dirigible(
            shell: #"exec "$0" "$@""#, dirigibleBinary.path, "marker", "set", package.path, "--name", "X", "--at", "0",
            limit: .seconds(10))

        #expect(result == CLIResult(status: 2, stdout: "", stderr: unsafeLockText(package)))
        #expect(try package.xml() == xml)
    }

    /// A placed take WAV that is a FIFO: `info` refuses the package at once, and does not wait for a
    /// writer in the read of its raw capture.
    @Test func aFIFOPoolFileStopsInfoAtOnce() async throws {
        let package = try await InfoCommandTests.rawPackage(bows: [1.07e-3])
        let wav = package.url.appending(path: "Clips/take1-1-1.wav").path
        try #require(unlink(wav) == 0 && mkfifo(wav, 0o644) == 0)

        let result = try await dirigible(
            shell: #"exec "$0" "$@""#, dirigibleBinary.path, "info", package.path, limit: .seconds(10))

        #expect(
            result
                == CLIResult(
                    status: 2, stdout: "", stderr: "Error: \(Self.unsafeItemText(package, "Clips/take1-1-1.wav"))\n"))
    }

    /// C15. `Clips` is a link out of the package: the dry run of a prune refuses the package, so it
    /// lists no file of the link target.
    @Test func aClipsLinkIsRefusedByPrune() async throws {
        let package = try Self.pruneEscape()

        let result = try await package.run("file", "prune", "--dry-run", "PKG")

        #expect(result == CLIResult(status: 2, stdout: "", stderr: "Error: \(Self.unsafeItemText(package, "Clips"))\n"))
        #expect(try Self.victimFiles(package) == Self.victim)
    }

    /// The files of `victim/` beside the package of `pruneEscape()`, by name.
    static let victim = ["notes.txt": Data("victim notes".utf8), "old.wav": Data("RIFF".utf8)]

    /// `Clips` is a link to `../victim`, and the pool entry
    /// `notes.txt` has no clip.
    static func pruneEscape() throws -> TemporaryPackage {
        let package = try TemporaryPackage()
        let folder = package.folder.appending(path: "victim")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for (name, data) in victim { try data.write(to: folder.appending(path: name)) }
        try FileManager.default.createDirectory(at: package.url, withIntermediateDirectories: false)
        try Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <session xmlns="https://github.com/niltsiar/dirigible/session" version="12" sampleRate="48000">
              <files>
                <file id="f1" path="notes.txt" channels="1" length="1"/>
              </files>
            </session>

            """.utf8
        ).write(to: package.sessionXML)
        try FileManager.default.createSymbolicLink(
            atPath: package.url.appending(path: "Clips").path, withDestinationPath: "../victim")
        return package
    }

    static func victimFiles(_ package: TemporaryPackage) throws -> [String: Data] {
        let folder = package.folder.appending(path: "victim")
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            result[name] = try Data(contentsOf: folder.appending(path: name))
        }
        return result
    }

    /// The refusal text of a `.lock` that is a link or a special file.
    func unsafeLockText(_ package: TemporaryPackage) -> String { "Error: \(Self.unsafeItemText(package, ".lock"))\n" }

    /// The refusal text of an item that is a link or a special file, with no prefix.
    static func unsafeItemText(_ package: TemporaryPackage, _ item: String) -> String {
        "\(package.path)/\(item) is a link or a special file. Dirigible opens a package only when its files and "
            + "folders are plain files and folders."
    }
}
