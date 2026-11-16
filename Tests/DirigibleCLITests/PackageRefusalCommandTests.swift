import DirigibleCore
import Foundation
import Testing

/// The commands refuse a package from another person that breaks a rule of the package format
/// (decision 0003), with exit 2 and no output of its content.
struct PackageRefusalCommandTests {
    /// C3. The audit input `xxe.dirigible`: an external entity in `session.xml` names a canary
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
}
