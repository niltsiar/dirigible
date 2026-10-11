import Foundation
import Testing

/// `dirigible --version` prints the `CFBundleShortVersionString` of the app that holds the tool
/// at `Contents/Helpers/dirigible`, also through a symlink (README links it into
/// /usr/local/bin). Outside an app bundle it prints 0.0.0 (releases.md, Versions).
struct VersionCommandTests {
    /// A copy of the built tool at `<folder>/Fake.app/Contents/Helpers/dirigible`, with an
    /// Info.plist of `entries` in `Contents`.
    private func fakeApp(_ entries: [String: String]) throws -> (TemporaryPackage, URL) {
        let temporary = try TemporaryPackage()
        let contents = temporary.folder.appending(path: "Fake.app/Contents")
        let tool = contents.appending(path: "Helpers/dirigible")
        try FileManager.default.createDirectory(
            at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dirigibleBinary, to: tool)
        let plist = try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
        try plist.write(to: contents.appending(path: "Info.plist"))
        return (temporary, tool)
    }

    @Test func theToolInAnAppPrintsTheAppVersion() async throws {
        let (temporary, tool) = try fakeApp(["CFBundleShortVersionString": "9.9.9"])
        let result = try await dirigible(shell: #"exec "$0" --version"#, tool.path)
        #expect(result == CLIResult(status: 0, stdout: "9.9.9\n", stderr: ""))
        withExtendedLifetime(temporary) {}
    }

    @Test func aSymlinkToTheToolPrintsTheAppVersion() async throws {
        let (temporary, tool) = try fakeApp(["CFBundleShortVersionString": "9.9.9"])
        let link = temporary.folder.appending(path: "bin/dirigible")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
        let result = try await dirigible(shell: #"exec "$0" --version"#, link.path)
        #expect(result == CLIResult(status: 0, stdout: "9.9.9\n", stderr: ""))
        // A bare name found through PATH, as with the folder of the link in ~/.zprofile.
        let found = try await dirigible(
            shell: #"PATH="$0:$PATH" exec dirigible --version"#, link.deletingLastPathComponent().path)
        #expect(found == CLIResult(status: 0, stdout: "9.9.9\n", stderr: ""))
        withExtendedLifetime(temporary) {}
    }

    @Test func anAppWithNoVersionGivesTheFallback() async throws {
        let (temporary, tool) = try fakeApp(["CFBundleName": "Fake"])
        let result = try await dirigible(shell: #"exec "$0" --version"#, tool.path)
        #expect(result == CLIResult(status: 0, stdout: "0.0.0\n", stderr: ""))
        withExtendedLifetime(temporary) {}
    }

    @Test func theToolOutsideAnAppPrintsTheFallback() async throws {
        #expect(try await dirigible("--version") == CLIResult(status: 0, stdout: "0.0.0\n", stderr: ""))
    }
}
