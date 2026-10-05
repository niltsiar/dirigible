import DirigibleCore
import Foundation
import Testing

struct SessionCommandTests {
    @Test func createMakesAnEmptySession() async throws {
        let package = try TemporaryPackage()
        #expect(
            try await dirigible("create", package.path, "--sample-rate", "48000")
                == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try package.read() == Session(sampleRate: 48_000))
        #expect(
            try await dirigible("info", package.path)
                == CLIResult(status: 0, stdout: "Show.dirigible: 48000 Hz\n", stderr: ""))
    }

    @Test func createRefusesExistingPackage() async throws {
        let package = try TemporaryPackage(Session(sampleRate: 44_100))
        let before = try package.xml()
        #expect(
            try await dirigible("create", package.path, "--sample-rate", "48000")
                == CLIResult(status: 2, stdout: "", stderr: "Error: \(package.path) exists.\n"))
        #expect(try package.xml() == before)
    }

    @Test func createRefusesPathWithoutExtension() async throws {
        let package = try TemporaryPackage()
        let path = package.folder.appending(path: "Show").path
        #expect(try await dirigible("create", path, "--sample-rate", "48000").status == 64)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test(arguments: ["0", "-48000"]) func createRefusesRateThatIsNotPositive(rate: String) async throws {
        let package = try TemporaryPackage()
        #expect(try await dirigible("create", package.path, "--sample-rate", rate).status == 64)
        #expect(!FileManager.default.fileExists(atPath: package.path))
    }

    @Test func infoRefusesMissingPackage() async throws {
        let package = try TemporaryPackage()
        #expect(
            try await dirigible("info", package.path)
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: cannot read \(package.path)/session.xml: No such file or directory.\n"))
    }

    @Test func infoRefusesNewerVersion() async throws {
        let package = try TemporaryPackage(Session(sampleRate: 48_000))
        let xml = String(decoding: try package.xml(), as: UTF8.self)
        try Data(xml.replacingOccurrences(of: "version=\"1\"", with: "version=\"6\"").utf8).write(
            to: package.sessionXML)
        #expect(
            try await dirigible("info", package.path)
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: \(package.path)/session.xml was made by a newer version of Dirigible (session "
                        + "version 6). This build reads version 5 or lower.\n"))
    }

    @Test func unknownSubcommandIsAUsageError() async throws {
        #expect(try await dirigible("frobnicate").status == 64)
    }

    @Test func missingArgumentIsAUsageError() async throws {
        #expect(try await dirigible("info").status == 64)
    }
}
