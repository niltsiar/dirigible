import CMainStack
import Foundation
import Testing

@testable import DirigibleAudio

/// The folders and the fake Mac of the bundle tests. No name is a value of this Mac.
struct BundleFixture {
    let temporary: TemporaryFolder
    var folder: URL { temporary.url }
    var logs: URL { folder.appending(path: "logs") }
    var reports: URL { folder.appending(path: "reports") }

    init() throws {
        temporary = try TemporaryFolder()
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
    }

    static let names = (
        home: "/Users/fixture-home", user: "qvo", full: "Quinn Ortega", computer: "Studio Mac Seven",
        hosts: ["Studio-Mac-Seven", "studio-mac-seven.local", "studio-mac-seven"]
    )

    static var redaction: Redaction {
        Redaction(
            home: names.home, user: names.user, fullName: names.full, computer: names.computer, hosts: names.hosts)
    }

    /// A private value, the kind of its rule, and if a match must be a whole word.
    struct Value {
        let kind: String
        let text: String
        let wholeWord: Bool
    }

    static let privateValues = [
        Value(kind: "home", text: names.home, wholeWord: false), Value(kind: "user", text: "qvo", wholeWord: true),
        Value(kind: "full", text: "Quinn Ortega", wholeWord: false),
        Value(kind: "full", text: "Quinn", wholeWord: true),
        Value(kind: "full", text: "Ortega", wholeWord: true),
        Value(kind: "computer", text: "Studio Mac Seven", wholeWord: false),
        Value(kind: "host", text: "studio-mac-seven", wholeWord: false),
    ]

    static func device(uid: String = "FixtureUID-A", name: String) -> BundleDevice {
        BundleDevice(
            uid: uid, name: name, channels: 2, rate: 48_000, transport: "usb", bufferFrames: 256, isDefaultInput: true,
            isDefaultOutput: false)
    }

    /// A journal, an `.ips` report, and a `.hang` report whose name holds the host name, each with
    /// the private values; and a report of another app.
    func writeNamedFiles() throws {
        let log = startLog(in: logs)
        log.note(
            .device, "attach-begin",
            [
                "name": .text("Quinn's AirPods"), "owner": .text("qvo"), "word": .text("aqvox"),
                "path": .text("/Users/fixture-home/Music/Show.dirigible"),
            ])
        log.quit()
        let ips = """
            {"procPath":"/Users/fixture-home/Applications/Dirigible.app","userID":"qvo","userName":"Quinn Ortega",
            "computerName":"Studio Mac Seven","hostName":"Studio-Mac-Seven.local","crashedBy":"qvo"}
            """
        try Data(ips.utf8).write(to: reports.appending(path: "Dirigible-2026-10-16-120000.ips"))
        try Data("Hostname: studio-mac-seven\nPath: /Users/fixture-home/x\n".utf8)
            .write(to: reports.appending(path: "Dirigible_2026-10-16-120000_studio-mac-seven.hang"))
        try Data("Quinn Ortega".utf8).write(to: reports.appending(path: "Zoom-2026-10-16-120000.ips"))
    }

    /// Writes `zip` in the folder with fake facts, and unzips it.
    func collect(
        devices: [BundleDevice] = [], reports: [URL]? = nil, redaction: Redaction = BundleFixture.redaction,
        zip name: String = "report.zip",
        walk: (@Sendable (ms_thread, UnsafeMutablePointer<UInt>, Int32) -> ms_walk_result)? = nil
    ) throws -> Unzipped {
        var facts = BundleFacts(
            version: "0.4.9", commit: "abc1234", devices: devices, defaultOutput: "Quinn's Speakers",
            microphone: .denied, freeBytes: 1_000, redaction: redaction)
        if let walk { facts.walk = walk }
        let zip = folder.appending(path: name)
        _ = try DiagnosticBundle.write(
            to: zip, days: 7, logs: logs, reports: reports ?? [self.reports], facts: facts, now: .now)
        return try Unzipped(zip, into: folder.appending(path: name + ".out"))
    }
}

/// An unzipped bundle: its entry names and its files under `Dirigible Report/`.
struct Unzipped {
    let root: URL
    let entries: [String]

    init(_ zip: URL, into folder: URL) throws {
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
        entries = try run("/usr/bin/zipinfo", ["-1", zip.path]).split(separator: "\n").map(String.init)
        root = folder.appending(path: "Dirigible Report")
    }

    func files(in group: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: group).path)) ?? []).sorted()
    }

    func text(_ path: String) throws -> String { try String(contentsOf: root.appending(path: path), encoding: .utf8) }

    /// The path of each file, from the root.
    var allFiles: [String] {
        let walk = FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String } ?? []
        return walk.filter {
            (try? root.appending(path: $0).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == false
        }
    }

    /// The files and the entry names that hold `value`, with no regard to case.
    func leaks(of value: BundleFixture.Value) -> [String] {
        allFiles.filter { ((try? text($0)).map { occurs(value, in: $0) }) ?? true }
            + entries.filter { occurs(value, in: $0) }
    }

    private func occurs(_ value: BundleFixture.Value, in text: String) -> Bool {
        let lower = text.lowercased()
        func isWord(_ character: Character?) -> Bool {
            character.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
        }
        return lower.ranges(of: value.text.lowercased()).contains { range in
            guard value.wholeWord else { return true }
            let before = range.lowerBound == lower.startIndex ? nil : lower[lower.index(before: range.lowerBound)]
            let after = range.upperBound == lower.endIndex ? nil : lower[range.upperBound]
            return !isWord(before) && !isWord(after)
        }
    }
}

/// Runs a tool of the system and gives its stdout. It throws when the tool fails.
@discardableResult
private func run(_ tool: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
    return String(decoding: data, as: UTF8.self)
}
