import DirigibleCore
import Foundation
import Testing

/// C27: `dirigible diagnostics collect` (decision 0059). The command reads the devices of the Mac
/// that runs the test, so the tests read only entry names, never the text of the zip.
struct DiagnosticsCommandTests {
    @Test func collectWritesTheFourGroups() async throws {
        let temporary = try TemporaryPackage(Session(sampleRate: 48_000))
        let logs = temporary.folder.appending(path: "journals")
        let reports = temporary.folder.appending(path: "reports")
        for folder in [logs, reports] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("dirigible-journal 1\n".utf8).write(to: logs.appending(path: "2026-10-16-120000-app-1.tsv"))
        try Data(repeating: 7, count: 32).write(to: logs.appending(path: "salt"))
        let kept = [
            "Dirigible-2026-10-16-120000.ips", "Dirigible_2026-10-16-120000.hang", "Dirigible_2026-10-16-120000.spin",
        ]
        for name in kept + ["Zoom-2026-10-16-120000.ips"] {
            try Data("report".utf8).write(to: reports.appending(path: name))
        }
        let zip = temporary.folder.appending(path: "report.zip")

        let result = try await dirigible([
            "diagnostics", "collect", zip.path, "--logs", logs.path, "--reports", reports.path,
        ])

        #expect(result.status == 0 && result.stdout == "Saved \(zip.path): 1 journals, 3 reports.\n", "\(result)")
        let entries = Set(try zipEntries(zip).filter { !$0.hasSuffix("/") })
        let expected = Set(
            ["summary.txt", "devices.tsv", "logs/2026-10-16-120000-app-1.tsv"] + kept.map { "reports/" + $0 }
        ).map { "Dirigible Report/" + $0 }
        #expect(entries == Set(expected), "entries: \(entries.sorted())")
    }

    /// Exit 2 for a zip path that exists, which keeps its bytes, and for a folder that does not
    /// exist, which stays missing.
    @Test func collectRefusesAnExistingOutput() async throws {
        let temporary = try TemporaryPackage(Session(sampleRate: 48_000))
        let zip = temporary.folder.appending(path: "report.zip")
        try Data("keep".utf8).write(to: zip)
        let lost = temporary.folder.appending(path: "no-folder/report.zip")
        let options = ["--logs", temporary.folder.path, "--reports", temporary.folder.path]

        let existing = try await dirigible(["diagnostics", "collect", zip.path] + options)
        let missing = try await dirigible(["diagnostics", "collect", lost.path] + options)

        #expect(existing == CLIResult(status: 2, stdout: "", stderr: "Error: \(zip.path) exists.\n"))
        #expect(try Data(contentsOf: zip) == Data("keep".utf8))
        let reason = "Error: \(lost.path) was not written: the folder of the zip does not exist.\n"
        #expect(missing == CLIResult(status: 2, stdout: "", stderr: reason))
        #expect(!FileManager.default.fileExists(atPath: lost.deletingLastPathComponent().path))
    }

    @Test func collectNeedsAnOutput() async throws {
        let result = try await dirigible("diagnostics", "collect")

        #expect(result.status == 64 && result.stderr.contains("Missing expected argument '<zip>'"), "\(result)")
    }
}

/// The entry names of a zip, from `zipinfo`.
private func zipEntries(_ zip: URL) throws -> [String] {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/zipinfo")
    process.arguments = ["-1", zip.path]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
}
