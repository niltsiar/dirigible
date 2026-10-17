import Foundation
import Testing
import os

@testable import DirigibleAudio

/// The parts, the retention, the unclean end, and the quit line of the journal (decision 0059).
extension DiagnosticLogTests {
    /// C4: a part limit of 4 KiB.
    @Test func aFullPartRotatesAndKeepsTheNewestLines() throws {
        let log = DiagnosticLog.start(
            .app, folder: folder.url, version: "0.4.9", commit: "abc1234", now: date("2026-10-16T19:20:00Z"),
            queue: DispatchQueue(label: "test.journal"), partLimit: 4096)
        let pad = String(repeating: "x", count: 40)
        for index in 0..<100 { log.note(.device, "input-gap", ["n": .number(Int64(index)), "pad": .text(pad)]) }
        log.drain()

        let stem = "2026-10-16-192000-app-\(getpid())"
        let files = journalFiles(in: folder.url)
        #expect(files.map(\.lastPathComponent) == ["\(stem).prev.tsv", "\(stem).tsv"])
        try #require(files.count == 2)
        let (older, newer) = (try journalLines(of: files[0]), try journalLines(of: files[1]))
        let longest = (older + newer).map { $0.utf8.count + 1 }.max() ?? 0
        for file in files {
            let size = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
            #expect(size <= 4096 + longest, "\(file.lastPathComponent): \(size) bytes")
        }
        for lines in [older, newer] {
            #expect(lines.count > 3 && lines[2].contains("\tapp\tlaunch\t"), "no launch line: \(lines.prefix(3))")
        }
        // The newest lines: the new part ends with the last line and goes on from the old part.
        #expect(number(newer.last) == 99)
        #expect(number(older.last).map { $0 + 1 } == number(newer[3]))
    }

    /// C5: 25 launches of each kind, a `.prev.tsv` part, the salt, and a file of another name.
    @Test func theStartKeepsTheNewest20LaunchesOfEachKindAnd50MiB() throws {
        for index in 0..<25 {
            for kind in ["app", "cli"] { try fixture(folder.url, kind, index) }
        }
        try Data("old part\n".utf8).write(to: folder.url.appending(path: "\(fixtureStem("app", 0)).prev.tsv"))
        try Data("old part\n".utf8).write(to: folder.url.appending(path: "\(fixtureStem("app", 24)).prev.tsv"))
        try Data(repeating: 1, count: 32).write(to: folder.url.appending(path: "salt"))
        try Data("keep\n".utf8).write(to: folder.url.appending(path: "notes.txt"))

        startLog(in: folder.url).drain()

        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.url.path))
        let new = "2026-10-16-192000-app-\(getpid()).tsv"
        let app = Set((6..<25).map { "\(fixtureStem("app", $0)).tsv" } + [new, "\(fixtureStem("app", 24)).prev.tsv"])
        let cli = Set((5..<25).map { "\(fixtureStem("cli", $0)).tsv" })
        #expect(names == app.union(cli).union(["salt", "notes.txt"]), "extra: \(names.subtracting(app.union(cli)))")

        // Three sparse journals of 30 MiB: only the newest stays under the byte limit.
        let large = folder.url.appending(path: "large")
        try FileManager.default.createDirectory(at: large, withIntermediateDirectories: false)
        for index in 0..<3 {
            let path = large.appending(path: "\(fixtureStem("app", index)).tsv").path
            #expect(FileManager.default.createFile(atPath: path, contents: nil) && truncate(path, 30 << 20) == 0)
        }

        startLog(.cli, in: large).drain()

        let kept = try FileManager.default.contentsOfDirectory(atPath: large.path).filter { $0.contains("-app-") }
        #expect(kept == ["\(fixtureStem("app", 2)).tsv"])
    }

    /// C44: 21 older app launches; the oldest has the PID of this process.
    @Test func theStartKeepsTheFileOfALivePID() throws {
        for index in 0..<21 { try fixture(folder.url, "app", index, pid: index == 0 ? getpid() : nil) }

        startLog(in: folder.url).drain()

        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.url.path))
        #expect(names.contains("\(fixtureStem("app", 0, pid: getpid())).tsv"))
        #expect(!names.contains("\(fixtureStem("app", 1)).tsv") && !names.contains("\(fixtureStem("app", 2)).tsv"))
        #expect(names.filter { $0.contains("-app-") }.count == 20)
    }

    enum EarlierLaunch: CaseIterable { case quit, otherLastLine, none, livePID }

    /// C6: one case for each start state.
    @Test(arguments: EarlierLaunch.allCases) func theStartFindsAnUncleanPreviousLaunch(_ earlier: EarlierLaunch) throws
    {
        let last =
            "2026-10-16T18:05:00.000Z\t2\tmain\tnotice\t" + (earlier == .quit ? "app\tquit" : "take\tstart-request")
        if earlier != .none {
            try fixture(folder.url, "app", 0, pid: earlier == .livePID ? getpid() : nil, last: last)
        }

        let log = startLog(in: folder.url)
        log.drain()

        let unclean = earlier == .otherLastLine
        #expect(log.previousEndedUnclean == unclean)
        let file = folder.url.appending(path: "2026-10-16-192000-app-\(getpid()).tsv")
        let lines = try journalLines(of: file)
        let marks = lines.filter { $0.contains("\tapp\tprevious-unclean\t") }
        #expect(marks.count == (unclean ? 1 : 0), "lines: \(lines)")
        if unclean {
            #expect(marks.first?.hasSuffix("\tlast=take start-request\tlast_time=2026-10-16T18:05:00.000Z") == true)
        }
    }

    /// C7: no barrier after the quit.
    @Test func quitIsTheLastLine() throws {
        let log = startLog(in: folder.url)
        for index in 0..<1000 { log.note(.device, "input-gap", ["n": .number(Int64(index))]) }
        log.quit()

        let lines = try journalLines(of: try #require(journalFiles(in: folder.url).first))
        #expect(lines.count == 1004)
        #expect(lines.last?.split(separator: "\t").dropFirst(4).prefix(2) == ["app", "quit"])
    }

    /// C7: a journal queue that does not run (a stalled disk) holds `quit()` for its 1 s bound only.
    @Test func aStalledQueueEndsQuitWithinTheBound() async throws {
        let queue = DispatchQueue(label: "test.journal.stalled")
        let log = DiagnosticLog.start(
            .app, folder: folder.url, version: "0.4.9", commit: "abc1234", now: date("2026-10-16T19:20:00Z"),
            queue: queue)
        queue.suspend()
        // The release of a suspended queue traps, so each exit resumes it.
        defer { queue.resume() }
        let returned = OSAllocatedUnfairLock(initialState: false)
        Thread {
            log.quit()
            returned.withLock { $0 = true }
        }.start()

        let deadline = ContinuousClock.now + .seconds(5)
        while !returned.withLock({ $0 }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(returned.withLock { $0 }, "quit() did not return in 5 s")
        let lines = try journalLines(of: try #require(journalFiles(in: folder.url).first))
        #expect(!lines.contains { $0.hasSuffix("\tapp\tquit") }, "lines: \(lines)")
    }
}

/// The stem of fixture launch `index` of `kind`, one minute apart on 2026-10-15. With no `pid`,
/// a PID over the macOS limit of 99 999, so no process has it.
private func fixtureStem(_ kind: String, _ index: Int, pid: Int32? = nil) -> String {
    "2026-10-15-10\(String(format: "%02d", index))00-\(kind)-\(pid ?? Int32(100_000 + index))"
}

/// A journal of an earlier launch whose last line is `last`.
private func fixture(_ folder: URL, _ kind: String, _ index: Int, pid: Int32? = nil, last: String? = nil) throws {
    var text = "dirigible-journal 1\ntime\tuptime_ms\tthread\tlevel\tcategory\tevent\tfields...\n"
    text += "2026-10-15T10:00:00.000Z\t1\tmain\tnotice\tapp\tlaunch\tversion=0.4.8\n"
    if let last { text += last + "\n" }
    try Data(text.utf8).write(to: folder.appending(path: "\(fixtureStem(kind, index, pid: pid)).tsv"))
}

/// The `n` field of a journal line.
private func number(_ line: String?) -> Int? {
    line?.firstMatch(of: #/\tn=(\d+)(\t|$)/#).flatMap { Int($0.1) }
}
