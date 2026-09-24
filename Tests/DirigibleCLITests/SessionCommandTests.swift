import DirigibleCore
import Foundation
import Testing

struct SessionCommandTests {
    @Test func createMakesAnEmptySession() throws {
        let package = try TemporaryPackage()
        #expect(
            try dirigible("create", package.path, "--sample-rate", "48000")
                == CLIResult(status: 0, stdout: "", stderr: ""))
        #expect(try package.read() == Session(sampleRate: 48_000))
        #expect(
            try dirigible("info", package.path)
                == CLIResult(status: 0, stdout: "Show.dirigible: 48000 Hz\n", stderr: ""))
    }

    @Test func createRefusesExistingPackage() throws {
        let package = try TemporaryPackage(Session(sampleRate: 44_100))
        let before = try package.xml()
        #expect(
            try dirigible("create", package.path, "--sample-rate", "48000")
                == CLIResult(status: 2, stdout: "", stderr: "Error: \(package.path) exists.\n"))
        #expect(try package.xml() == before)
    }

    @Test func createRefusesPathWithoutExtension() throws {
        let package = try TemporaryPackage()
        let path = package.folder.appending(path: "Show").path
        #expect(try dirigible("create", path, "--sample-rate", "48000").status == 64)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test(arguments: ["0", "-48000"]) func createRefusesRateThatIsNotPositive(rate: String) throws {
        let package = try TemporaryPackage()
        #expect(try dirigible("create", package.path, "--sample-rate", rate).status == 64)
        #expect(!FileManager.default.fileExists(atPath: package.path))
    }

    @Test func infoRefusesMissingPackage() throws {
        let package = try TemporaryPackage()
        #expect(
            try dirigible("info", package.path)
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: cannot read \(package.path)/session.xml: No such file or directory.\n"))
    }

    @Test func infoRefusesNewerVersion() throws {
        let package = try TemporaryPackage(Session(sampleRate: 48_000))
        let xml = String(decoding: try package.xml(), as: UTF8.self)
        try Data(xml.replacingOccurrences(of: "version=\"1\"", with: "version=\"2\"").utf8).write(
            to: package.sessionXML)
        #expect(
            try dirigible("info", package.path)
                == CLIResult(
                    status: 2, stdout: "",
                    stderr: "Error: \(package.path)/session.xml has version 2. This build reads version 1 or lower.\n"))
    }

    @Test func unknownSubcommandIsAUsageError() throws {
        #expect(try dirigible("frobnicate").status == 64)
    }

    @Test func missingArgumentIsAUsageError() throws {
        #expect(try dirigible("info").status == 64)
    }
}
