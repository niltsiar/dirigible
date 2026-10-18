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

    /// C44: 21 older app launches. The oldest is locked; the second has the PID of this process
    /// and no lock, as a PID that a new process got after a restart.
    @Test func theStartKeepsTheFileOfALockedJournal() throws {
        for index in 0..<21 { try fixture(folder.url, "app", index, pid: index == 1 ? getpid() : nil) }
        let locked = try lock(folder.url.appending(path: "\(fixtureStem("app", 0)).tsv"))
        defer { close(locked) }

        startLog(in: folder.url).drain()

        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.url.path))
        #expect(names.contains("\(fixtureStem("app", 0)).tsv"))
        #expect(!names.contains("\(fixtureStem("app", 1, pid: getpid())).tsv"))
        #expect(!names.contains("\(fixtureStem("app", 2)).tsv"))
        #expect(names.filter { $0.contains("-app-") }.count == 20)
    }

    enum EarlierLaunch: CaseIterable { case quit, otherLastLine, none, livePIDWithNoLock, locked }

    /// C6: one case for each start state. A live PID with no lock is a new process with the PID
    /// of the earlier launch (after a restart), so its end is unclean.
    @Test(arguments: EarlierLaunch.allCases) func theStartFindsAnUncleanPreviousLaunch(_ earlier: EarlierLaunch) throws
    {
        let last =
            "2026-10-16T18:05:00.000Z\t2\tmain\tnotice\t" + (earlier == .quit ? "app\tquit" : "take\tstart-request")
        if earlier != .none {
            try fixture(folder.url, "app", 0, pid: earlier == .livePIDWithNoLock ? getpid() : nil, last: last)
        }
        let locked = earlier == .locked ? try lock(folder.url.appending(path: "\(fixtureStem("app", 0)).tsv")) : -1
        defer { if locked >= 0 { close(locked) } }

        let log = startLog(in: folder.url)
        log.drain()

        let unclean = earlier == .otherLastLine || earlier == .livePIDWithNoLock
        #expect(log.previousEndedUnclean == unclean)
        let file = folder.url.appending(path: "2026-10-16-192000-app-\(getpid()).tsv")
        let lines = try journalLines(of: file)
        let marks = lines.filter { $0.contains("\tapp\tprevious-unclean\t") }
        #expect(marks.count == (unclean ? 1 : 0), "lines: \(lines)")
        if unclean {
            #expect(marks.first?.hasSuffix("\tlast=take start-request\tlast_time=2026-10-16T18:05:00.000Z") == true)
        }
    }

    /// C6: an earlier journal that another process locks is live. When that process ends, the
    /// kernel drops the lock, and the next start finds the unclean end.
    @Test func aJournalLockedByAnotherProcessIsLiveUntilItEnds() async throws {
        try fixture(folder.url, "app", 0, last: "2026-10-16T18:05:00.000Z\t2\tmain\tnotice\ttake\tstart-request")
        let file = folder.url.appending(path: "\(fixtureStem("app", 0)).tsv")
        let helper = Process()
        helper.executableURL = URL(filePath: "/usr/bin/lockf")
        helper.arguments = ["-k", file.path, "/bin/cat"]
        let input = Pipe()
        helper.standardInput = input
        try helper.run()
        defer { if helper.isRunning { helper.terminate() } }
        try await poll("the helper did not lock the journal") { isLocked(file) }

        let during = startLog(in: folder.url, at: "2026-10-16T19:20:00Z")
        during.drain()
        // The journal of `during` stays locked by this process, so the next start reads the fixture.
        try FileManager.default.removeItem(at: folder.url.appending(path: "2026-10-16-192000-app-\(getpid()).tsv"))
        try input.fileHandleForWriting.close()
        try await poll("the helper did not end") { !helper.isRunning }
        let after = startLog(in: folder.url, at: "2026-10-16T19:21:00Z")
        after.drain()

        #expect(!during.previousEndedUnclean)
        #expect(after.previousEndedUnclean)
    }

    /// C6: the caller runs only the open and the preamble write. The queue is held, so an
    /// earlier journal that gets its quit line after the start counts as clean, and the first
    /// start has no salt before the queue runs.
    @Test func theStartReadsNoOtherFileOnTheCaller() throws {
        try fixture(folder.url, "app", 0, last: "2026-10-16T18:05:00.000Z\t2\tmain\tnotice\ttake\tstart-request")
        let queue = DispatchQueue(label: "test.journal.held")
        queue.suspend()
        // The release of a suspended queue traps, so each exit resumes it.
        var resumed = false
        defer { if !resumed { queue.resume() } }
        let log = DiagnosticLog.start(
            .app, folder: folder.url, version: "0.4.9", commit: "abc1234", now: date("2026-10-16T19:20:00Z"),
            queue: queue)
        let preamble = try journalLines(of: folder.url.appending(path: "2026-10-16-192000-app-\(getpid()).tsv"))
        let salted = FileManager.default.fileExists(atPath: folder.url.appending(path: "salt").path)
        let earlier = try FileHandle(forWritingTo: folder.url.appending(path: "\(fixtureStem("app", 0)).tsv"))
        try earlier.seekToEnd()
        try earlier.write(contentsOf: Data("2026-10-16T18:06:00.000Z\t3\tmain\tnotice\tapp\tquit\n".utf8))
        try earlier.close()
        queue.resume()
        resumed = true

        #expect(preamble.count == 3, "the preamble is not on the caller: \(preamble)")
        #expect(!salted, "the caller wrote the salt")
        #expect(!log.previousEndedUnclean, "the caller read the earlier journal")
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

    /// C7: a writer queue that notes a line after `quit()` (an abandoned attach) adds no line
    /// after `app quit`. The quit drops the lock, so the next start reads that last line.
    @Test func aNoteAfterQuitLeavesACleanEnd() throws {
        let log = startLog(in: folder.url, at: "2026-10-16T19:20:00Z")
        log.note(.take, "start-request")
        log.quit()
        log.note(.device, "attach", ["device": .text("USB Mic")])
        log.drain()
        let file = folder.url.appending(path: "2026-10-16-192000-app-\(getpid()).tsv")
        let locked = isLocked(file)
        let next = startLog(in: folder.url, at: "2026-10-16T19:21:00Z")
        next.drain()

        let events = try journalLines(of: file).dropFirst(3).map {
            $0.split(separator: "\t").dropFirst(4).prefix(2).joined(separator: " ")
        }
        #expect(events == ["take start-request", "app quit"], "\(events)")
        #expect(!locked, "the journal keeps its lock after the quit")
        #expect(!next.previousEndedUnclean)
    }

    /// C7: a child process between posix_spawn and exec holds a copy of the journal descriptor
    /// (a parallel test spawns one). The quit drops the lock of that copy too.
    @Test func theQuitDropsTheLockThatAChildCopyHolds() throws {
        let log = startLog(in: folder.url)
        let file = folder.url.appending(path: "2026-10-16-192000-app-\(getpid()).tsv")
        let child = try spawnSleepWithACopy(of: file)
        defer {
            kill(child, SIGKILL)
            waitpid(child, nil, 0)
        }
        log.quit()
        log.drain()

        #expect(!isLocked(file), "the copy in the child keeps the lock after the quit")
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

    /// C7: the lines before the quit line drain at the QoS of the `quit()` caller, not at the
    /// `.utility` QoS of the queue, so a backlog meets the 1 s bound under load. A line block on
    /// the queue reads the priority of its thread until it rises or `quit()` returns.
    @Test func quitRaisesThePriorityOfTheQueuedLines() async throws {
        let queue = DispatchQueue(label: "test.journal.utility", qos: .utility)
        let log = DiagnosticLog.start(
            .app, folder: folder.url, version: "0.4.9", commit: "abc1234", now: date("2026-10-16T19:20:00Z"),
            queue: queue)
        let drain = OSAllocatedUnfairLock(initialState: (started: false, raised: false, returned: false))
        queue.async {
            let start = threadPriority()
            drain.withLock { $0.started = true }
            var raised = false
            while !raised, !drain.withLock({ $0.returned }) {
                let now = threadPriority()
                raised = now.base > start.base || now.current > start.current
            }
            drain.withLock { [raised] in $0.raised = raised }
        }
        try await poll("the line block did not start") { drain.withLock { $0.started } }
        let quitter = Thread {
            log.quit()
            drain.withLock { $0.returned = true }
        }
        quitter.qualityOfService = .userInitiated
        quitter.start()
        try await poll("quit() did not return") { drain.withLock { $0.returned } }

        #expect(drain.withLock { $0.raised }, "the queued lines drained at .utility while quit() waited")
    }
}

extension DiagnosticLogTests {
    /// C8: a `hang` line and a `fault` line drain at user-interactive QoS behind the lines
    /// before them, so they never wait for the `.utility` queue under load. A line block on the
    /// queue reads the priority of its thread until it rises, at most 5 s.
    @Test(arguments: [false, true]) func aHangOrFaultLineRaisesThePriorityOfTheQueuedLines(fault: Bool) async throws {
        let queue = DispatchQueue(label: "test.journal.utility", qos: .utility)
        let log = DiagnosticLog.start(
            .app, folder: folder.url, version: "0.4.9", commit: "abc1234", now: date("2026-10-16T19:20:00Z"),
            queue: queue)
        let drain = OSAllocatedUnfairLock(initialState: (started: false, raised: false, done: false))
        queue.async {
            let start = threadPriority()
            drain.withLock { $0.started = true }
            let deadline = ContinuousClock.now + .seconds(5)
            var raised = false
            while !raised, ContinuousClock.now < deadline {
                let now = threadPriority()
                raised = now.base > start.base || now.current > start.current
            }
            drain.withLock { [raised] in
                $0.raised = raised
                $0.done = true
            }
        }
        try await poll("the line block did not start") { drain.withLock { $0.started } }
        log.note(.take, "start-request")
        // The watchdog queue is user-interactive, and the main thread notes the fault lines.
        let noter = Thread {
            if fault { log.note(.device, "lost", level: .fault) } else { log.note(.hang, "start") }
        }
        noter.qualityOfService = .userInteractive
        noter.start()
        try await poll("the line block did not end") { drain.withLock { $0.done } }
        log.drain()

        let line = fault ? "fault" : "hang"
        #expect(drain.withLock { $0.raised }, "the lines before the \(line) line drained at .utility")
        let events = try journalLines(of: try #require(journalFiles(in: folder.url).first)).dropFirst(3).map {
            $0.split(separator: "\t").dropFirst(4).prefix(2).joined(separator: " ")
        }
        #expect(events == ["take start-request", fault ? "device lost" : "hang start"], "\(events)")
    }
}

/// Returns when `condition` holds; throws after 5 s.
private func poll(_ message: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw PollTimeout(message: message) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private struct PollTimeout: Error, CustomStringConvertible {
    let message: String
    var description: String { "\(message) in 5 s" }
}

/// The base and the current scheduling priority of the calling thread.
private func threadPriority() -> (base: Int32, current: Int32) {
    var info = thread_extended_info()
    var count = mach_msg_type_number_t(MemoryLayout<thread_extended_info>.size / MemoryLayout<integer_t>.size)
    let thread = mach_thread_self()
    defer { mach_port_deallocate(mach_task_self_, thread) }
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &count)
        }
    }
    return (info.pth_priority, info.pth_curpri)
}

/// A new descriptor of `file` with an exclusive lock, as a live launch holds on its journal.
private func lock(_ file: URL) throws -> Int32 {
    let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_EXLOCK | O_NONBLOCK)
    try #require(descriptor >= 0, "the lock of \(file.lastPathComponent): errno \(errno)")
    return descriptor
}

/// True while a descriptor of another open holds a lock on `file`.
private func isLocked(_ file: URL) -> Bool {
    let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_SHLOCK | O_NONBLOCK)
    guard descriptor >= 0 else { return errno == EWOULDBLOCK }
    close(descriptor)
    return false
}

/// Starts `/bin/sleep` with a copy of the descriptor that this process holds on `file`, and no
/// other descriptor: a copy of a descriptor of a parallel test changes that test.
private func spawnSleepWithACopy(of file: URL) throws -> pid_t {
    var target = stat()
    try #require(stat(file.path, &target) == 0)
    let descriptor = try #require(
        (0..<getdtablesize()).first { candidate in
            var info = stat()
            return fstat(candidate, &info) == 0 && info.st_dev == target.st_dev && info.st_ino == target.st_ino
        })
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addinherit_np(&actions, descriptor)
    let argv = (["/bin/sleep", "60"] as [String]).map { strdup($0) } + [nil]
    defer { for pointer in argv { free(pointer) } }
    var child: pid_t = 0
    try #require(posix_spawn(&child, "/bin/sleep", &actions, &attributes, argv, environ) == 0)
    return child
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
