import CoreAudio
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// C15 to C19 and C39: the journal lines of a take start and stop, and the begin line of each
/// call that can block (decision 0059). The suite is serialized because its starts and stops
/// wait for writer queues that the tests hold.
@MainActor @Suite(.serialized)
struct TakeLogTests {
    static let zoom = "us.zoom.xos"
    let folder: TemporaryFolder
    let url: URL
    let logs: URL
    let log: DiagnosticLog
    let mic = StartLimitTests.device("mic", "USB Mic")
    let box = StartLimitTests.device("box", "Box")

    /// `t1` (Host) on `mic`, `t2` (Guest) on `box`, and `t4` (Call) on Zoom, all mono.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        logs = folder.url.appending(path: "logs")
        log = startLog(in: logs)
        var session = Session(sampleRate: 48_000)
        for (id, name) in [("t1", "Host"), ("t2", "Guest"), ("t4", "Call")] {
            try session.addTrack(TrackID(id), name: name, layout: .mono)
        }
        try session.setRoute(.device(uid: "mic", channels: .mono(1)), track: "t1")
        try session.setRoute(.device(uid: "box", channels: .mono(1)), track: "t2")
        try session.setRoute(.app(bundleID: Self.zoom), track: "t4")
        try session.write(to: url)
    }

    func studio(_ hal: TestHAL, access: MicrophoneAccess? = nil, free: Int64 = 100_000_000_000) async throws -> Studio {
        let studio = try await Studio.open(url, log: log)
        studio.environment = .test(hal, access: access, free: FreeBytes(free))
        studio.environment.log = log
        return studio
    }

    /// The lines of the journal after each queued line is written.
    nonisolated static func lines(_ log: DiagnosticLog, in logs: URL) -> [String] {
        log.drain()
        return journalFiles(in: logs).flatMap { (try? journalLines(of: $0)) ?? [] }
    }

    func lines() -> [String] { Self.lines(log, in: logs) }

    /// `<category> <event>` of each line, with no `app` line.
    func events(_ lines: [String]) -> [String] {
        lines.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count >= 6 && !["app", "category"].contains($0[4]) }.map { "\($0[4]) \($0[5])" }
    }

    /// The fields of the first line of `event` (`<category>\t<event>`), or nil.
    func fields(_ lines: [String], _ event: String) -> [String: String]? {
        lines.first { $0.contains("\t\(event)\t") || $0.hasSuffix("\t\(event)") }.map {
            fieldValues($0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init))
        }
    }

    func has(_ lines: [String], _ event: String) -> Bool { fields(lines, event) != nil }

    // MARK: C15

    /// A start of two device tracks writes each step in order. The device lines come from the
    /// writer queues, so the test checks only that each attach line comes after its begin line,
    /// within the writers and apps steps.
    @Test func aTakeStartWritesEachStepInOrder() async throws {
        let studio = try await studio(TestHAL([mic, box]))
        try await studio.startRecording(armed: ["t1", "t2"], playhead: 0)
        let lines = lines()
        try await studio.stopRecording()
        await studio.settle()

        let events = events(lines)
        #expect(
            events.filter { !$0.hasPrefix("device ") } == [
                "take start-request", "take write-chain", "take check-begin", "take check",
                "permission microphone-begin", "permission microphone", "disk free-begin", "disk free",
                "session save-begin", "session save", "take begin", "take arm", "take arm", "take writers-begin",
                "take writers", "take sleep-assertion-begin", "take sleep-assertion", "take apps-started",
                "take hand-over-begin", "take hand-over", "take started",
            ], "\(events)")
        let writers = try #require(events.firstIndex(of: "take writers-begin"))
        let apps = try #require(events.firstIndex(of: "take apps-started"))
        let rows = lines.map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count >= 6 && !["app", "category"].contains($0[4]) }
        for device in ["USB Mic", "Box"] {
            let begin = rows.firstIndex { $0[5] == "attach-begin" && fieldValues($0)["device"] == device }
            let end = rows.firstIndex { $0[5] == "attach" && fieldValues($0)["device"] == device }
            #expect(begin.map { $0 > writers } == true && end.map { $0 < apps } == true, "\(device): \(events)")
            #expect((begin ?? .max) < (end ?? .min), "\(device): \(events)")
        }
        let arm = try #require(fields(lines, "take\tarm"))
        #expect(arm["arm"] == "1" && arm["kind"] == "device" && arm["device"] == "USB Mic", "\(arm)")
        #expect(arm["rate"] == "48000" && arm["channels"] == "1", "\(arm)")
        #expect(arm["uid"]?.hasPrefix("uid-") == true, "\(arm)")
        #expect(fields(lines, "take\tbegin") == ["take": "1", "arms": "2"])
        let values = lines.flatMap { fieldValues($0.split(separator: "\t").map(String.init)).values }
        #expect(!values.contains { ["t1", "t2", "Host", "Guest", "mic", "box"].contains($0) }, "\(lines)")
    }

    // MARK: C16

    /// A start that throws writes one `take start-failed` line at level error with its case.
    @Test(arguments: [
        (StudioError.diskLow, "diskLow"), (.microphoneAccess(.denied), "microphoneAccess.denied"), (.busy, "busy"),
    ])
    func aFailedStartNamesItsError(_ error: StudioError, name: String) async throws {
        let studio = try await studio(
            TestHAL([mic, box]), access: error == .microphoneAccess(.denied) ? .denied : nil,
            free: error == .diskLow ? 1_000 : 100_000_000_000)
        if error == .busy { try await studio.startRecording(armed: ["t1"], playhead: 0) }

        await #expect(throws: error) { try await studio.startRecording(armed: ["t1"], playhead: 0) }

        let failed = lines().filter { $0.contains("\ttake\tstart-failed") }
        #expect(failed.count == 1, "\(failed)")
        let columns = try #require(failed.first).split(separator: "\t").map(String.init)
        #expect(columns[3] == "error" && fieldValues(columns)["error"] == name, "\(columns)")
        if error == .busy { try await studio.stopRecording() }
        await studio.settle()
    }

    // MARK: C17

    /// A device whose first attach waits past the start deadline is named, and its track is not
    /// started. The stop gives it up.
    @Test func aMissedStartDeadlineNamesTheWriter() async throws {
        let hal = TestHAL([mic, box])
        hal.holdAttach("box")
        defer { hal.releaseAttach("box") }
        let studio = try await studio(hal)
        studio.environment.startLimit = .milliseconds(500)

        try await studio.startRecording(armed: ["t1", "t2"], playhead: 0)
        try await studio.stopRecording()

        let lines = lines()
        #expect(fields(lines, "take\tstart-deadline")?["missed"] == "Box", "\(events(lines))")
        #expect(fields(lines, "take\tarm-not-started")?["arm"] == "2", "\(events(lines))")
        #expect(fields(lines, "take\tapps-started")?["missed"] == "1", "\(events(lines))")
        #expect(fields(lines, "take\tabandoned")?["writer"] == "Box", "\(events(lines))")
        hal.releaseAttach("box")
        await studio.settle()
    }

    // MARK: C18

    /// A stop writes its request, each writer with its finish time, and the result of the take.
    @Test func aStopWritesEachWriterAndTheResult() async throws {
        let hal = TestHAL([mic, box])
        let studio = try await studio(hal)
        let inputs = ["mic", "box"].map { uid in
            let input = SyntheticInput(hal, uid)
            var clock = DeviceClock(hostNanos: Double(takeStart) + 100_000_000)
            input.play(clock.run(seconds: 1), pace: .realTime, takeStartIn: url)
            return input
        }
        try await studio.startRecording(armed: ["t1", "t2"], playhead: 0)
        for input in inputs { await input.wait() }
        for uid in ["mic", "box"] { await drained(hal, uid) }

        try await studio.stopRecording()
        await studio.settle()

        let lines = lines()
        let events = events(lines)
        let request = try #require(events.firstIndex(of: "take stop-request"), "\(events)")
        let finished = events.indices.filter { events[$0] == "take writer-finished" }
        let result = try #require(events.firstIndex(of: "take finalized"), "\(events)")
        #expect(finished.count == 2 && finished.allSatisfy { $0 > request && $0 < result }, "\(events)")
        let writers = Set(
            lines.filter { $0.contains("\ttake\twriter-finished\t") }.compactMap {
                fieldValues($0.split(separator: "\t").map(String.init))["writer"]
            })
        #expect(writers == ["USB Mic", "Box"])
        let take = try #require(fields(lines, "take\tfinalized"))
        #expect(take["gaps"] == "1:none,2:none" && take["dropped"] == "1:0,2:0", "\(take)")
        #expect((take["wav"].flatMap { Int($0) } ?? 0) > 0 && take["seconds"] != nil && take["ms"] != nil, "\(take)")
    }

    /// A writer whose finish waits past the stop deadline is named, and no finalize runs. The stop
    /// writes the finish line of the writer when the writer answers, and Retry Finalize writes its
    /// count, the finish line again, and the result. Both finish lines time from the stop call.
    @Test func aStopPastTheDeadlineNamesTheLateWriter() async throws {
        let hal = TestHAL([mic])
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let studio = try await studio(hal)
        studio.environment.stopLimit = .milliseconds(500)
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        hal.holdNextDetach(in: gate)

        await #expect(throws: StudioError.writerDidNotStop("USB Mic")) { try await studio.stopRecording() }

        let held = lines()
        #expect(fields(held, "take\tstop-deadline")?["missed"] == "USB Mic", "\(events(held))")
        #expect(fields(held, "take\twriter-did-not-stop")?["writer"] == "USB Mic", "\(events(held))")
        #expect(!has(held, "take\tfinalized"), "\(events(held))")
        gate.open()
        let isMicFinished = { (line: String) in
            line.contains("\ttake\twriter-finished\t") && line.contains("\twriter=USB Mic")
        }
        await until(limit: .seconds(5), "no late writer-finished line of USB Mic") {
            self.lines().contains(where: isMicFinished)
        }
        try await studio.retryFinalize()
        let lines = lines()
        #expect(fields(lines, "take\tretry-finalize")?["unfinished"] == "1", "\(events(lines))")
        #expect(has(lines, "take\tfinalized"), "\(events(lines))")
        #expect(lines.filter(isMicFinished).count == 2, "\(events(lines))")
        let retry = try #require(lines.firstIndex { $0.contains("\ttake\tretry-finalize") }, "\(events(lines))")
        let retried = try #require(lines[retry...].first(where: isMicFinished), "\(events(lines))")
        let ms = fieldValues(retried.split(separator: "\t", omittingEmptySubsequences: false).map(String.init))["ms"]
        #expect((ms.flatMap(Double.init) ?? 0) >= 500, "\(retried)")
        await studio.settle()
    }

    // MARK: C19

    /// Each attach writes its begin line and its line with the duration of the HAL call.
    @Test func anAttachLineHasItsDuration() async throws {
        let hal = TestHAL([mic])
        hal.delayAttach("mic", by: .milliseconds(1200))
        let studio = try await studio(hal)

        try await studio.startRecording(armed: ["t1"], playhead: 0)

        let lines = lines()
        let attach = try #require(fields(lines, "device\tattach"), "\(events(lines))")
        #expect((attach["ms"].flatMap { Double($0) } ?? 0) >= 1200, "\(attach)")
        #expect(attach["device"] == "USB Mic" && attach["status"] == "0", "\(attach)")
        #expect(has(lines, "device\tattach-begin"))
        try await studio.stopRecording()
        await studio.settle()
    }

    // MARK: C39

    /// A HAL call that does not return leaves its begin line in the file: the attach of a device,
    /// or the tap of an app.
    @Test(arguments: [false, true]) func aHeldAttachLeavesItsBeginLineInTheFile(app: Bool) async throws {
        let hal = TestHAL([mic])
        hal.setApp(Self.zoom, StartLimitTests.found([41]), name: "zoom.us")
        if app { hal.holdTaps() } else { hal.holdAttach("mic") }
        defer { if app { hal.releaseTaps() } else { hal.releaseAttach("mic") } }
        let studio = try await studio(hal)
        studio.environment.startLimit = .milliseconds(500)
        let (begin, end) = app ? ("tap\tcreate-begin", "tap\tcreate") : ("device\tattach-begin", "device\tattach")

        let start = Task { try await studio.startRecording(armed: [app ? "t4" : "t1"], playhead: 0) }
        await until(limit: .seconds(5), "no \(begin) line during the held call") { has(lines(), begin) }

        #expect(!has(lines(), end), "\(events(lines()))")
        if app { hal.releaseTaps() } else { hal.releaseAttach("mic") }
        try await start.value
        try await studio.stopRecording()
        await studio.settle()
    }

    /// A studio whose Player plays a clip of `t1` on `mic`, and its package, which the caller keeps.
    func playingStudio() async throws -> (Studio, MixPackage) {
        let package = try MixPackage()
        try package.addFile("f1", channels: [ramp(frames: 100_000)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 48_000)
        try package.session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try package.session.write(to: package.url)
        let studio = try await Studio.open(package.url, log: log)
        studio.environment = .test(TestHAL([mic]))
        studio.environment.log = log
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 4800)
        return (studio, package)
    }

    enum Step: CaseIterable { case playStop, sleepAssertion, microphone, diskFree, sessionSave }

    /// Each start call with a seam finds its begin line in the file, and not its own line, while
    /// the call runs: the seam reads the file.
    @Test(arguments: Step.allCases) func aHeldStartCallLeavesItsBeginLine(step: Step) async throws {
        let played = step == .playStop ? try await playingStudio() : nil
        let studio: Studio
        if let played { studio = played.0 } else { studio = try await self.studio(TestHAL([mic])) }
        let (log, logs) = (log, logs)
        let seen = OSAllocatedUnfairLock<[String]?>(initialState: nil)
        let read: @Sendable () -> Void = { seen.withLock { $0 = Self.lines(log, in: logs) } }
        let (begin, end): (String, String)
        switch step {
        case .playStop:
            #expect(studio.play.player != nil, "no Player to stop")
            studio.environment.beforePlayerStop = { read() }
            (begin, end) = ("take\tplay-stop-begin", "take\tplay-stop")
        case .sleepAssertion:
            studio.environment.makeSleepAssertion = {
                read()
                return SleepAssertion()
            }
            (begin, end) = ("take\tsleep-assertion-begin", "take\tsleep-assertion")
        case .microphone:
            studio.environment.microphoneAccess = {
                read()
                return nil
            }
            (begin, end) = ("permission\tmicrophone-begin", "permission\tmicrophone")
        case .diskFree:
            studio.environment.freeBytes = { _ in
                read()
                return 100_000_000_000
            }
            (begin, end) = ("disk\tfree-begin", "disk\tfree")
        case .sessionSave:
            studio.environment.beforeTakeSave = { read() }
            (begin, end) = ("session\tsave-begin", "session\tsave")
        }

        try await studio.startRecording(armed: ["t1"], playhead: 0)

        let during = try #require(seen.withLock { $0 }, "the seam of \(step) did not run")
        #expect(has(during, begin) && !has(during, end), "\(step): \(events(during))")
        #expect(has(lines(), end), "\(step): \(events(lines()))")
        try await studio.stopRecording()
        await studio.settle()
        withExtendedLifetime(played) {}
    }
}
