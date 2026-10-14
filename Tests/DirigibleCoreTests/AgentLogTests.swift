import Foundation
import Testing

@testable import DirigibleCore

/// The agent log of a package (decision 0050, C16).
struct AgentLogTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "agent-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func entry(_ event: AgentLog.Event = .click, take: Int? = 3, agent: String? = "Claude Code") -> AgentLog.Entry {
        AgentLog.Entry(
            time: Date(timeIntervalSince1970: 1_800_000_000), event: event, take: take, agent: agent, connection: 7,
            tracks: ["Host", "Guest"], seconds: 90)
    }

    func lines(_ package: URL) throws -> [String] {
        try String(contentsOf: package.appending(path: AgentLog.fileName), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    @Test func appendsOneLineAfterTheHeader() throws {
        #expect(AgentLog.append(entry(), to: folder) == .written)
        #expect(AgentLog.append(entry(.declined, take: nil, agent: "a\tb\nc"), to: folder) == .written)

        let lines = try lines(folder)
        #expect(lines.count == 5 && lines.last == "", "\(lines)")
        #expect(lines[0] == "# Dirigible agent log, version 1")
        #expect(lines[1] == "time\tevent\ttake\tagent\tconnection\ttracks\tseconds")
        let time = ISO8601DateFormatter.string(
            from: Date(timeIntervalSince1970: 1_800_000_000), timeZone: .current, formatOptions: [.withInternetDateTime]
        )
        #expect(lines[2] == "\(time)\tclick\t3\tClaude Code\t7\tHost, Guest\t90")
        #expect(lines[3] == "\(time)\tdeclined\t-\ta b c\t7\tHost, Guest\t90", "a tab or a line break becomes a space")
        #expect(lines[2].split(separator: "\t").count == 7, "seven fields")
    }

    /// Decision 0024 P4: a newer file gets no line; a first line that does not parse gets none.
    @Test(arguments: [
        ("# Dirigible agent log, version 2\nx\n", AgentLog.Result.newer(2)),
        ("time\tevent\n", .unreadable),
        ("# Dirigible agent log, version +1\n", .unreadable),
    ])
    func noLineInAFileItCannotRead(text: String, result: AgentLog.Result) throws {
        let file = folder.appending(path: AgentLog.fileName)
        try Data(text.utf8).write(to: file)
        #expect(AgentLog.append(entry(), to: folder) == result)
        #expect(try Data(contentsOf: file) == Data(text.utf8), "the file did not change")
    }

    /// A file of 0 bytes counts as new.
    @Test func anEmptyFileGetsTheHeader() throws {
        try Data().write(to: folder.appending(path: AgentLog.fileName))
        #expect(AgentLog.append(entry(), to: folder) == .written)
        #expect(try lines(folder).prefix(2) == ["# Dirigible agent log, version 1", AgentLog.header])
    }

    /// 100 appends to two packages through the writer keep their order, with one header each.
    @Test func theWriterKeepsTheOrder() async throws {
        let (one, two) = (folder.appending(path: "one"), folder.appending(path: "two"))
        for package in [one, two] {
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        }
        for n in 0..<100 { AgentLogWriter.append(entry(take: n), to: n.isMultiple(of: 2) ? one : two) }
        AgentLogWriter.drain()
        for (package, first) in [(one, 0), (two, 1)] {
            let lines = try lines(package).dropLast()
            #expect(lines.filter { $0 == AgentLog.header }.count == 1)
            let takes = lines.dropFirst(2).map { $0.split(separator: "\t")[2] }
            #expect(takes == stride(from: first, to: 100, by: 2).map { Substring("\($0)") })
        }
    }

    /// A log that ends in a partial line from a failed write takes the next line whole, on a new
    /// line (item 4 of code gate 1).
    @Test func aPartialLineDoesNotJoinTheNext() throws {
        let partial = "# Dirigible agent log, version 1\n\(AgentLog.header)\n2026-10-14T08:00:00+02:00\tcli"
        try Data(partial.utf8).write(to: folder.appending(path: AgentLog.fileName))
        #expect(AgentLog.append(entry(), to: folder) == .written)
        let lines = try lines(folder)
        #expect(lines[2] == "2026-10-14T08:00:00+02:00\tcli")
        #expect(lines[3].split(separator: "\t").count == 7, "\(lines)")
    }

    /// A failed first write leaves no file, so a later append writes the version line and the
    /// header.
    @Test func aFailedFirstWriteBlocksNothing() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        #expect(AgentLog.append(entry(), to: folder) == .failed(EACCES))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "no partial file")
        #expect(AgentLog.append(entry(), to: folder) == .written)
        #expect(try lines(folder).prefix(2) == ["# Dirigible agent log, version 1", AgentLog.header])
    }

    /// A write failure gives its errno.
    @Test func aReadOnlyFolderFails() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        #expect(AgentLog.append(entry(), to: folder) == .failed(EACCES))
    }
}
