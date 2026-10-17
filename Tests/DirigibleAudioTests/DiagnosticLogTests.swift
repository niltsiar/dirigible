import Foundation
import Testing
import os

@testable import DirigibleAudio

/// The journal of decision 0059: one file for each launch in a temporary folder.
struct DiagnosticLogTests {
    let folder: TemporaryFolder

    init() throws { folder = try TemporaryFolder() }

    /// C1.
    @Test func aStartWritesTheVersionLineTheHeaderAndTheLaunchLine() throws {
        let log = startLog(in: folder.url, at: "2026-10-16T19:20:00Z")
        log.drain()

        let files = journalFiles(in: folder.url)
        #expect(files.map(\.lastPathComponent) == ["2026-10-16-192000-app-\(getpid()).tsv"])
        let lines = try journalLines(of: try #require(files.first))
        try #require(lines.count == 3, "lines: \(lines)")
        #expect(lines[0] == "dirigible-journal 1")
        #expect(lines[1] == "time\tuptime_ms\tthread\tlevel\tcategory\tevent\tfields...")
        let launch = lines[2].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        #expect(launch[0] == "2026-10-16T19:20:00.000Z")
        #expect(launch[3...5] == ["notice", "app", "launch"])
        let fields = fieldValues(launch)
        #expect(fields["version"] == "0.4.9")
        #expect(fields["commit"] == "abc1234")
        #if arch(arm64)
            #expect(fields["arch"] == "arm64")
        #else
            #expect(fields["arch"] == "x86_64")
        #endif
        let system = ProcessInfo.processInfo.operatingSystemVersion
        #expect(fields["macos"]?.hasPrefix("\(system.majorVersion).\(system.minorVersion)") == true)
        #expect(fields["model"]?.isEmpty == false)
        #expect(fields["locale"]?.isEmpty == false)
    }

    /// C2: a second descriptor reads the line while the journal keeps its own open.
    @Test func aNotedLineIsInTheFileBeforeTheClose() throws {
        let log = startLog(in: folder.url)
        log.note(.take, "start-request", ["armed": .number(2)])
        log.drain()

        let lines = try journalLines(of: try #require(journalFiles(in: folder.url).first))
        try #require(lines.count == 4, "lines: \(lines)")
        let columns = lines[3].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        #expect(columns[3...] == ["notice", "take", "start-request", "armed=2"])
    }

    /// C2: the queue is held while 1000 lines wait. A block queued after the first line reads
    /// the file, so it sees each line that the drains before it wrote.
    @Test func oneDrainWritesEachLineThatWaits() throws {
        let queue = DispatchQueue(label: "test.journal.held")
        let log = DiagnosticLog.start(
            .app, folder: folder.url, version: "0.4.9", commit: "abc1234", now: date("2026-10-16T19:20:00Z"),
            queue: queue)
        let file = try #require(journalFiles(in: folder.url).first)
        let seen = OSAllocatedUnfairLock<Int?>(initialState: nil)
        queue.suspend()
        log.note(.device, "input-gap", ["n": .number(0)])
        queue.async { seen.withLock { $0 = (try? journalLines(of: file))?.count } }
        for index in 1..<1000 { log.note(.device, "input-gap", ["n": .number(Int64(index))]) }
        queue.resume()
        log.drain()

        #expect(seen.withLock { $0 } == 1003, "the file had fewer lines after the first drain")
        #expect(try journalLines(of: file).count == 1003)
    }

    /// C3.
    @Test func aFieldValueEscapesTheTabTheNewlineAndTheBackslash() throws {
        let log = startLog(in: folder.url)
        log.note(.device, "attach", ["device": .text("A\tB\nC\\D\r")])
        log.drain()

        let lines = try journalLines(of: try #require(journalFiles(in: folder.url).first))
        #expect(lines.count == 4)
        #expect(lines.last?.hasSuffix("\tdevice=A\\tB\\nC\\\\D\\r") == true, "line: \(lines.last ?? "")")
    }

    /// C3: two launches in one folder give one token for one UID, and no raw value.
    @Test func aUIDAndAPackageAreTokensInTheFile() throws {
        let uid = "AppleUSBAudioEngine:Focusrite:Scarlett 2i2:14130000:1"
        let package = URL(filePath: "/Users/tester/Podcasts/Secret Show.dirigible")
        for time in ["2026-10-16T19:20:00Z", "2026-10-16T19:21:00Z"] {
            let log = startLog(in: folder.url, at: time)
            log.note(.device, "attach", ["uid": .uid(uid), "package": .package(package)])
            log.drain()
        }

        let texts = try journalFiles(in: folder.url).map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }
        try #require(texts.count == 2)
        #expect(texts.allSatisfy { !$0.contains(uid) && !$0.contains("Secret Show") && !$0.contains("tester") })
        let uids = texts.compactMap { $0.firstMatch(of: #/\tuid=(uid-[0-9a-f]{8})(\t|\n)/#).map { String($0.1) } }
        let packages = texts.compactMap {
            $0.firstMatch(of: #/\tpackage=(pkg-[0-9a-f]{8})(\t|\n)/#).map { String($0.1) }
        }
        #expect(uids.count == 2 && Set(uids).count == 1, "uid tokens: \(uids)")
        #expect(packages.count == 2 && Set(packages).count == 1, "package tokens: \(packages)")
    }

    /// C3: in a folder with no salt, a second start runs between the temporary write and the move
    /// of the first, so the second puts its salt in place first.
    @Test func twoStartsAtOnceShareOneSalt() throws {
        var second: Data?
        let first = try Journal.readSalt(in: folder.url) {
            second = try? Journal.readSalt(in: folder.url).withUnsafeBytes { Data($0) }
        }

        let salt = try Data(contentsOf: folder.url.appending(path: "salt"))
        #expect(salt.count == 32)
        #expect(second == salt, "the second start does not use the salt in the file")
        #expect(first.withUnsafeBytes { Data($0) } == salt, "the first start does not use the salt in the file")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        #expect(names == ["salt"], "files: \(names)")
    }

    /// C3.
    @Test func aShortSaltIsReplaced() throws {
        let salt = folder.url.appending(path: "salt")
        try Data(repeating: 7, count: 10).write(to: salt)

        _ = startLog(in: folder.url)

        #expect(try Data(contentsOf: salt).count == 32)
    }

    /// C40.
    @Test func aFolderWithNoWriteGivesADisabledLog() throws {
        let locked = folder.url.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        #expect(chmod(locked.path, 0o555) == 0)
        defer { chmod(locked.path, 0o755) }

        let log = startLog(in: locked)
        for index in 0..<1000 { log.note(.take, "start-request", ["n": .number(Int64(index))]) }
        log.quit()

        #expect(!log.isEnabled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path) == [])
    }

    /// C44.
    @Test func theFolderComesFromTheEnvironment() {
        let home = URL(filePath: NSHomeDirectory()).appending(path: "Library/Logs/Dirigible").path
        #expect(DiagnosticLog.folder(environment: ["DIRIGIBLE_LOG_FOLDER": "/tmp/journals"]).path == "/tmp/journals")
        #expect(DiagnosticLog.folder(environment: [:]).path == home)
        #expect(DiagnosticLog.folder(environment: ["DIRIGIBLE_LOG_FOLDER": ""]).path == home)
    }
}

/// A start of `kind` in `folder` at `time` (ISO 8601), with set build facts.
func startLog(_ kind: DiagnosticLog.Kind = .app, in folder: URL, at time: String = "2026-10-16T19:20:00Z")
    -> DiagnosticLog
{
    DiagnosticLog.start(kind, folder: folder, version: "0.4.9", commit: "abc1234", now: date(time))
}

func date(_ iso: String) -> Date { try! Date(iso, strategy: .iso8601) }

/// The journal parts in `folder`, by name.
func journalFiles(in folder: URL) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter { $0.hasSuffix(".tsv") }.sorted().map { folder.appending(path: $0) }
}

func journalLines(of file: URL) throws -> [String] {
    String(decoding: try Data(contentsOf: file), as: UTF8.self).split(separator: "\n").map(String.init)
}

/// The `key=value` columns of a split line, after its six fixed columns.
func fieldValues(_ columns: [String]) -> [String: String] {
    Dictionary(
        columns.dropFirst(6).map { column in
            let parts = column.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }, uniquingKeysWith: { $1 })
}
