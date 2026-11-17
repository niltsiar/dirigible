import DirigibleCore
import Foundation
import Testing

/// A damaged `session.xml` from another person ends a command with exit 2 and the text of a
/// damaged file, never with a signal. Each case runs in a `dirigible` child, so a crash names
/// its test and does not stop the shard.
struct HostileSessionCommandTests {
    static let root =
        #"<session xmlns="https://github.com/niltsiar/dirigible/session" version="12" sampleRate="48000">"#
    static let unclosed = String(repeating: "<a>", count: 100_000)

    /// `dirigible info` on a package whose `session.xml` is `xml`.
    static func info(_ xml: String) async throws -> (CLIResult, path: String) {
        let package = try TemporaryPackage(Session(sampleRate: 48_000))
        try Data(xml.utf8).write(to: package.sessionXML)
        return (try await package.run("info", "PKG"), package.path)
    }

    /// Boundary fuzz C4, X7: 100,000 nested elements that do not close.
    @Test func deepUnclosedNestingExitsTwo() async throws {
        let (result, path) = try await Self.info(
            #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n" + Self.root + Self.unclosed)

        #expect(
            result
                == CLIResult(
                    status: 2, stdout: "", stderr: "Error: \(path)/session.xml is not a Dirigible session file.\n"))
    }

    /// Boundary fuzz C4, X22: an element name of 60,000 bytes stops the parser pass before the
    /// depth count, then 100,000 nested elements that do not close.
    @Test func aLongNameBeforeDeepNestingExitsTwo() async throws {
        let name = String(repeating: "n", count: 60_000)
        let (result, path) = try await Self.info(
            #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n" + Self.root + "<\(name)>" + Self.unclosed)

        #expect(
            result
                == CLIResult(
                    status: 2, stdout: "", stderr: "Error: \(path)/session.xml is not a Dirigible session file.\n"))
    }
}
