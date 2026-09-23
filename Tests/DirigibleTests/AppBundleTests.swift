import Foundation
import Testing

/// Checks the app bundle that `scripts/bundle.sh` builds. `make test-app` builds the bundle
/// and sets `DIRIGIBLE_APP` to its path, so these tests never read a stale bundle.
/// Without the variable they fail: `make test` skips this suite by name instead.
struct AppBundleTests {
    let app: URL

    init() throws {
        let path = try #require(ProcessInfo.processInfo.environment["DIRIGIBLE_APP"], "Run through make test-app")
        app = URL(filePath: path)
    }

    var executable: String { app.appending(path: "Contents/MacOS/Dirigible").path }

    @Test func infoPlistDeclaresSonomaAndMicrophoneUse() throws {
        let data = try Data(contentsOf: app.appending(path: "Contents/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        #expect(plist["LSMinimumSystemVersion"] as? String == "14.0")
        #expect(plist["CFBundleExecutable"] as? String == "Dirigible")
        let micReason = try #require(plist["NSMicrophoneUsageDescription"] as? String)
        #expect(!micReason.isEmpty)
    }

    @Test func binaryRunsOnSonomaOnIntelAndAppleSilicon() throws {
        #expect(try run("/usr/bin/lipo", "-archs", executable).split(separator: " ").sorted() == ["arm64", "x86_64"])

        let minimums = try run("/usr/bin/vtool", "-show-build", executable)
            .split(separator: "\n").filter { $0.contains("minos") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(minimums == ["minos 14.0", "minos 14.0"])
    }

    @Test func bundleSignatureIsValid() throws {
        _ = try run("/usr/bin/codesign", "--verify", "--strict", app.path)
    }

    private func run(_ tool: String, _ arguments: String...) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw ToolFailure(command: ([tool] + arguments).joined(separator: " "), output: text)
        }
        return text
    }
}

struct ToolFailure: Error, CustomStringConvertible {
    let command: String
    let output: String
    var description: String { "\(command) failed: \(output)" }
}
