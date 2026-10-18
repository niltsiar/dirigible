import CMainStack
import CryptoKit
import Foundation
import Testing

@testable import DirigibleAudio

/// The problem report of decision 0059: C28 to C31, C45, and C48. Each name, device, and file is
/// a fixture of the test, never a value of this Mac.
struct DiagnosticBundleTests {
    /// C28: each row of the cause table of the analysis is one fixture line. The early rows rotate
    /// into the `.prev.tsv` part, and a journal older than the days stays out.
    @Test func eachCauseRowIsInTheBundle() throws {
        let fixture = try BundleFixture()
        let log = DiagnosticLog.start(
            .app, folder: fixture.logs, version: "0.4.9", commit: "abc1234", now: .now, queue: Journal.makeQueue(),
            partLimit: 3_500)
        let rows: [(DiagnosticCategory, StaticString)] = [
            (.device, "attach"), (.device, "devices-changed"), (.device, "come-back"), (.tap, "create"),
            (.take, "start-deadline"), (.take, "abandoned"), (.hang, "start"), (.hang, "stack"), (.hang, "end"),
            (.permission, "microphone"), (.tap, "silence"), (.take, "finalized"), (.device, "lost"),
            (.device, "back"), (.device, "input-gap"), (.device, "dropped"), (.take, "start-failed"),
            (.take, "writer-did-not-stop"), (.take, "finalize-failed"), (.app, "previous-unclean"),
            (.disk, "free"), (.disk, "threshold"), (.take, "stopped"), (.recovery, "found"), (.recovery, "done"),
            (.agent, "call"), (.take, "arm"),
        ]
        for (number, row) in rows.enumerated() {
            log.note(row.0, row.1, ["row": .number(Int64(number)), "pad": .text(String(repeating: "x", count: 40))])
        }
        log.quit()
        let parts = journalFiles(in: fixture.logs).map(\.lastPathComponent)
        try #require(parts.count == 2 && parts.contains { $0.hasSuffix(".prev.tsv") }, "parts: \(parts)")
        let written = try parts.map { try String(contentsOf: fixture.logs.appending(path: $0), encoding: .utf8) }
        try #require(rows.allSatisfy { row in written.contains { $0.contains(Self.column(row)) } })
        let old = fixture.logs.appending(path: "2026-01-02-030405-app-1.tsv")
        try Data("dirigible-journal 1\n2026-01-02T03:04:05.000Z\t1\tmain\tnotice\ttake\told-row\n".utf8).write(to: old)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-10 * 86_400)], ofItemAtPath: old.path)

        let bundle = try fixture.collect()

        let text = try bundle.files(in: "logs").map { try bundle.text("logs/" + $0) }.joined()
        let dropped = rows.filter { !text.contains(Self.column($0)) }.map { "\($0.0) \($0.1)" }
        #expect(dropped.isEmpty, "the bundle drops \(dropped)")
        #expect(bundle.files(in: "logs").count == 2 && !text.contains("old-row"), "logs: \(bundle.files(in: "logs"))")
    }

    static func column(_ row: (DiagnosticCategory, StaticString)) -> String { "\t\(row.0.rawValue)\t\(row.1)\t" }

    /// C29: no file and no entry name holds a name of the user or of the Mac. A device name keeps
    /// its other words, and a short name stays inside a longer word.
    @Test func theBundleHoldsNoUserOrMacName() throws {
        let fixture = try BundleFixture()
        try fixture.writeNamedFiles()

        let bundle = try fixture.collect(devices: [BundleFixture.device(name: "Quinn's AirPods")])

        for value in BundleFixture.privateValues {
            let leaks = bundle.leaks(of: value)
            #expect(leaks.isEmpty, "\(value.text) is in \(leaks)")
        }
        #expect(try bundle.text("devices.tsv").contains("\tUSER's AirPods\t"))
        let journal = try #require(bundle.files(in: "logs").first)
        #expect(try bundle.text("logs/" + journal).contains("word=aqvox"), "the whole-word rule")
        #expect(bundle.entries.contains { $0.hasSuffix("reports/Dirigible_2026-10-16-120000_HOST-NAME.hang") })
    }

    /// The control of C29: with the rule of one kind of name removed, the same fixtures show that
    /// name in the bundle, so each rule is needed and the scan finds each name.
    @Test func eachNameLeaksWithoutItsRule() throws {
        let fixture = try BundleFixture()
        try fixture.writeNamedFiles()
        let names = BundleFixture.names
        let without: [(String, Redaction)] = [
            (
                "home",
                Redaction(
                    home: "", user: names.user, fullName: names.full, computer: names.computer, hosts: names.hosts)
            ),
            (
                "user",
                Redaction(
                    home: names.home, user: "", fullName: names.full, computer: names.computer, hosts: names.hosts)
            ),
            (
                "full",
                Redaction(
                    home: names.home, user: names.user, fullName: "", computer: names.computer, hosts: names.hosts)
            ),
            (
                "computer",
                Redaction(home: names.home, user: names.user, fullName: names.full, computer: nil, hosts: names.hosts)
            ),
            (
                "host",
                Redaction(home: names.home, user: names.user, fullName: names.full, computer: names.computer, hosts: [])
            ),
        ]
        for (kind, redaction) in without {
            let bundle = try fixture.collect(redaction: redaction, zip: "\(kind).zip")
            let values = BundleFixture.privateValues.filter { $0.kind == kind }
            #expect(
                !values.isEmpty && values.allSatisfy { !bundle.leaks(of: $0).isEmpty }, "no leak with no \(kind) rule")
        }
    }

    /// C30: the summary has the Mac facts, and a line for a report folder that cannot be read.
    @Test func theSummaryNamesEachSkippedGroup() throws {
        let fixture = try BundleFixture()
        let locked = fixture.folder.appending(path: "locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appending(path: "Dirigible-2026-10-16-120000.ips"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let missing = fixture.folder.appending(path: "missing")

        let bundle = try fixture.collect(reports: [locked, missing])

        let lines = try bundle.text("summary.txt").split(separator: "\n").map(String.init)
        for key in [
            "version 0.4.9", "commit abc1234", "macos ", "arch ", "model ", "free_bytes 1000", "microphone denied",
        ] {
            #expect(lines.contains { $0.hasPrefix(key) }, "no \(key) line")
        }
        #expect(lines.contains("default_output USER's Speakers"))
        let skipped = lines.filter { $0.hasPrefix("skipped ") }
        #expect(
            skipped == ["skipped reports \(locked.path): no read permission (a system folder needs an administrator)"],
            "\(skipped)")
        #expect(bundle.files(in: "reports").isEmpty)
    }

    /// C45: one device has one token in both launch journals and in `devices.tsv`, and neither the
    /// UID nor the salt is in the zip.
    @Test func oneDeviceHasOneTokenInEveryFile() throws {
        let fixture = try BundleFixture()
        let uid = "FixtureUID-0001:4,2"
        for second in ["2026-10-16T10:00:00Z", "2026-10-16T11:00:00Z"] {
            let log = startLog(in: fixture.logs, at: second)
            log.note(.device, "attach", ["uid": .uid(uid)])
            log.quit()
        }
        let salt = try Data(contentsOf: fixture.logs.appending(path: "salt")).map { String(format: "%02x", $0) }
            .joined()

        let bundle = try fixture.collect(devices: [BundleFixture.device(uid: uid, name: "Desk Mic")])

        let journals = try bundle.files(in: "logs").map { try bundle.text("logs/" + $0) }
        let devices = try bundle.text("devices.tsv")
        try #require(journals.count == 2)
        let tokens = Set((journals + [devices]).flatMap { $0.matches(of: /uid-[0-9a-f]{8}/).map { String($0.0) } })
        #expect(tokens.count == 1, "tokens: \(tokens)")
        #expect(journals.allSatisfy { $0.contains(tokens.first ?? "-") } && devices.contains(tokens.first ?? "-"))
        let all = try bundle.allFiles.map { try bundle.text($0) }
        #expect(!all.contains { $0.contains(uid) || $0.contains(salt) }, "the UID or the salt is in the zip")
        #expect(!bundle.entries.contains { $0.lowercased().contains("salt") }, "entries: \(bundle.entries)")
    }

    /// C31: `devices.tsv` has the columns of `dirigible devices`, then the transport, the buffer,
    /// and the default flags, with the HMAC-SHA256 token of the salt in place of the UID.
    @Test func theDeviceListHasTokensNotUIDs() throws {
        let fixture = try BundleFixture()
        startLog(in: fixture.logs).quit()
        let salt = SymmetricKey(data: try Data(contentsOf: fixture.logs.appending(path: "salt")))
        let first = BundleFixture.device(uid: "FixtureUID-A", name: "Desk Mic")
        let second = BundleDevice(
            uid: "FixtureUID-B", name: "Tab\tName", channels: 8, rate: 44_100, transport: "blue", bufferFrames: nil,
            isDefaultInput: false, isDefaultOutput: true)

        let bundle = try fixture.collect(devices: [first, second])

        func expected(_ uid: String) -> String {
            "uid-"
                + HMAC<SHA256>.authenticationCode(for: Data(uid.utf8), using: salt).prefix(4)
                .map { String(format: "%02x", $0) }.joined()
        }
        let lines = try bundle.text("devices.tsv").split(separator: "\n").map(String.init)
        #expect(
            lines == [
                "uid\tname\tchannels\trate\ttransport\tbuffer_frames\tdefault_input\tdefault_output",
                "\(expected("FixtureUID-A"))\tDesk Mic\t2\t48000\tusb\t256\t1\t0",
                "\(expected("FixtureUID-B"))\tTab\\tName\t8\t44100\tblue\tunknown\t0\t1",
            ], "\(lines)")
        #expect(try bundle.text("summary.txt").contains("default_input Desk Mic \(expected("FixtureUID-A"))\n"))
    }

    /// C48: the summary has the result of one walk of a helper thread. A walk that gives no
    /// frames gives the failed line.
    @Test func theSummaryHasTheWalkSelfCheck() throws {
        let fixture = try BundleFixture()

        let bundle = try fixture.collect()
        let failed = try fixture.collect(zip: "failed.zip") { _, _, _ in
            ms_walk_result(status: KERN_SUCCESS, count: 0, suspended_at: 0, resumed_at: 0)
        }

        let walk = try bundle.text("summary.txt").split(separator: "\n").first { $0.hasPrefix("stack walk ") } ?? ""
        let match = walk.wholeMatch(of: /stack walk ok frames=(\d+) named=(\d+) helper=yes system=yes/)
        #expect((match.flatMap { Int($0.1) } ?? 0) >= 3, "\(walk)")
        #expect(
            try failed.text("summary.txt").contains("stack walk failed frames=0 named=0 helper=no system=no status=0\n")
        )
    }

    /// A spindump report (`.hang`, `.spin`) holds the stacks of each process of the Mac. The zip
    /// keeps its header and its first process with the binary images, and no name of another one.
    @Test(arguments: ["hang", "spin"]) func aSpindumpReportKeepsOnlyItsFirstProcess(kind: String) throws {
        let fixture = try BundleFixture()
        let report = """
            Date/Time:        2026-10-16 12:00:00.000 +0200
            Report Version:   35

            Process:          Dirigible [101]
            Path:             /Applications/Dirigible.app/Contents/MacOS/Dirigible
              Thread 0x1a  DispatchQueue "com.apple.main-thread"  1000 samples
                1000 main + 10 (Dirigible) [0x100001000]

            Binary Images:
              0x100000000 - 0x1000fffff  Dirigible (0.4.9) <A1B2C3D4> /Applications/Dirigible.app/Contents/MacOS/Dirigible

            Process:          FixtureVideoCall [202]
            Path:             /Applications/FixtureVideoCall.app/Contents/MacOS/FixtureVideoCall
              Thread 0x2b  1000 samples
                1000 start + 1 (FixtureVideoCall) [0x200001000]

            Binary Images:
              0x200000000 - 0x2000fffff  FixtureVideoCall (3.1) <E5F6A7B8> /Applications/FixtureVideoCall.app/x

            """
        try Data(report.utf8).write(to: fixture.reports.appending(path: "Dirigible_2026-10-16-120000_Mac.\(kind)"))

        let bundle = try fixture.collect()

        let copied = try bundle.text("reports/Dirigible_2026-10-16-120000_Mac.\(kind)")
        #expect(copied.hasPrefix("Date/Time:        2026-10-16 12:00:00.000 +0200\nReport Version:   35\n"))
        #expect(copied.contains("main + 10 (Dirigible)") && copied.contains("<A1B2C3D4>"), "the first process stays")
        #expect(!copied.contains("FixtureVideoCall") && !copied.contains("E5F6A7B8"), "no other process")
    }

    /// A spindump report is read up to `hangReportLimit` bytes, so one report cannot make a zip
    /// of any size.
    @Test func aSpindumpReportIsCutAtTheSizeLimit() throws {
        let fixture = try BundleFixture()
        let line = "    100 frame_" + String(repeating: "x", count: 100) + " + 4 (Dirigible) [0x100001000]\n"
        let lines = DiagnosticBundle.hangReportLimit / line.utf8.count + 100
        let report = "Process:          Dirigible [101]\n" + String(repeating: line, count: lines)
        try Data(report.utf8).write(to: fixture.reports.appending(path: "Dirigible_2026-10-16-120000_Mac.hang"))

        let bundle = try fixture.collect()

        let copied = try bundle.text("reports/Dirigible_2026-10-16-120000_Mac.hang")
        #expect(copied.utf8.count <= DiagnosticBundle.hangReportLimit && copied.hasPrefix("Process:"))
        #expect(copied.utf8.count > DiagnosticBundle.hangReportLimit - 1_000, "the report is cut, not dropped")
    }

    /// The redaction of random text: a text with no name stays the same, and a name between two
    /// such texts becomes its replacement.
    @Test func aRandomTextKeepsItsOtherWords() {
        var random = SeededGenerator(seed: 59)
        let words = ["take", "arm", "marker_set", "aqvox", "Studio", "Mac", "/Users/other", "uid-1234abcd", "\t", "x"]
        let names = [
            ("qvo", "USER"), ("QUINN", "USER"), ("Ortega", "USER"), (BundleFixture.names.home, "~"),
            ("Studio Mac Seven", "MAC-NAME"), ("studio-mac-seven", "HOST-NAME"),
        ]
        let redaction = BundleFixture.redaction
        for _ in 0..<200 {
            let plain = (0..<12).map { _ in words.randomElement(using: &random)! }.joined(separator: " ")
            #expect(redaction.apply(plain) == plain, "\(plain)")
            let (name, replacement) = names.randomElement(using: &random)!
            let mixed = redaction.apply(plain + " " + name + " " + plain)
            #expect(mixed == plain + " " + replacement + " " + plain, "\(mixed)")
        }
    }
}
