import CoreAudio
import DirigibleCore
import Foundation
import Observation
import Testing

@testable import DirigibleAudio

/// The pause of each chunk of an export that a test cancels: 10 chunks are 10 s. A full suite
/// holds the main actor for seconds, so a shorter export can end before the poll of the test
/// sees it start or before the cancel. The cancel ends it at the next chunk.
let longChunk: TimeInterval = 1

/// The chunk seam of a Studio export (`CaptureEnvironment.exportChunk`): it records the thread
/// and the QoS of each chunk, runs an action at a chunk, then pauses.
final class ChunkSeam: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(main: Bool, qos: qos_class_t, priority: TaskPriority)] = []
    private let pause: TimeInterval
    private let actions: [Int: @Sendable () -> Void]

    init(pause: TimeInterval = 0, at actions: [Int: @Sendable () -> Void] = [:]) {
        self.pause = pause
        self.actions = actions
    }

    var calls: Int { lock.withLock { records.count } }
    var onMain: [Bool] { lock.withLock { records.map(\.main) } }
    var qos: [qos_class_t] { lock.withLock { records.map(\.qos) } }
    /// `Task.currentPriority` at each chunk: the priority of a Swift task with its escalation,
    /// or the priority of the QoS of a thread that runs no task.
    var priorities: [TaskPriority] { lock.withLock { records.map(\.priority) } }

    func step() {
        let call = lock.withLock { () -> Int in
            records.append((Thread.isMainThread, qos_class_self(), Task.currentPriority))
            return records.count
        }
        actions[call]?()
        guard pause > 0 else { return }
        // The probe of the unheld pause cannot run on the main thread, so the pause never ends.
        guard !Thread.isMainThread else {
            Issue.record("A paused export chunk ran on the main thread")
            return
        }
        // The pause leaves out the main-actor holds of other suites, so an export that a test
        // cancels does not end while the test waits for the main actor (run flakes-2, S4). The
        // wall cap of 3 x the pause ends it when the holds do not end.
        let watch = Stopwatch()
        while watch.elapsed < .seconds(pause), watch.wall < .seconds(pause * 3) { Thread.sleep(forTimeInterval: 0.05) }
    }
}

/// A package for the Studio export tests: track `t1` on `mic` channel 1, with clip `c1` of a
/// 1 kHz sine at -20 dBFS RMS, 10 s long (10 chunks of 48 000 frames).
struct ExportStudioFixture {
    let package: MixPackage
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!
    let source = ExportSource(range: 0..<480_000)!
    let options = ExportOptions(format: .wav(.bits24), layout: .stereo, rate: .session)
    var out: URL { package.folder.url.appending(path: "mix.wav") }

    /// Writes the package off the main actor. `extra` adds to the package before the write.
    @concurrent nonisolated static func make(
        _ extra: @Sendable (MixPackage) throws -> Void = { _ in }
    ) async throws -> sending ExportStudioFixture {
        let package = try MixPackage()
        try package.addFile("f1", channels: [ExportTests.tone(frames: 480_000)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 480_000)
        try package.session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try extra(package)
        try package.session.write(to: package.url)
        return ExportStudioFixture(package: package)
    }

    @MainActor func open(_ hal: TestHAL? = nil, seam: ChunkSeam = ChunkSeam()) async throws -> Studio {
        let studio = try await Studio.open(package.url)
        studio.environment = .test(hal ?? TestHAL([mic]))
        studio.environment.exportChunk = { seam.step() }
        return studio
    }

    /// The `.tmp` files next to the export target.
    func temporaryFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.folder.url.path).filter { $0.hasSuffix(".tmp") }
    }

    /// Checks that `url` holds the 10 s export of the tone. It reads off the main actor, so the
    /// `@MainActor` tests of other suites do not wait for it.
    @concurrent nonisolated static func expectTheExport(at url: URL) async throws {
        let written = try ExportTests.read(url)
        #expect(written.length == 480_000)
        #expect(abs(ExportTests.rmsDB(written.channels[0]) - -20) <= 0.01)
    }
}

/// The take gates of a Studio export (export run criteria 1, 20, and 21).
@MainActor
struct StudioExportTests {
    enum StartPath: CaseIterable { case startRecording, startTake }

    /// A paused chunk on the main thread is an issue with a name, not a hang: the main-actor
    /// probe of the pause cannot run there (code gate 1 of run flakes-2, item 1).
    @Test func aPausedChunkOnTheMainThreadIsAnIssue() {
        // The probe last ran before this test: 0.5 s later, its lag passes 1 s during the pause.
        _ = MainActorHolds.shared.total
        Thread.sleep(forTimeInterval: 0.5)
        let watch = Stopwatch()
        withKnownIssue {
            ChunkSeam(pause: longChunk).step()
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("main thread") }
        }
        #expect(watch.wall < .seconds(longChunk * 3 + 1))
    }

    /// Starts `path` on `t1`, and returns the host time of the take start.
    func start(_ path: StartPath, _ studio: Studio, _ fixture: ExportStudioFixture) async throws(StudioError) -> UInt64
    {
        switch path {
        case .startRecording:
            // After the start: the take start host time is read after the export ends.
            try await studio.startRecording(armed: ["t1"])
            return AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        case .startTake:
            _ = try await studio.startTake(armed: ["t1"], devices: [fixture.mic], hostTimeNanos: takeStart)
            return takeStart
        }
    }

    /// Plays 0.25 s into `mic`, stops the take, and checks that `t1` has the take clip.
    func recordAndStop(_ studio: Studio, _ hal: TestHAL, from host: UInt64) async throws {
        let input = SyntheticInput(hal, "mic")
        input.play(records([sine(seconds: 0.25, rate: 48_000)], layout: [1], rate: 48_000, hostStart: host))
        await input.wait()
        try await studio.stopRecording()
        #expect(studio.session.track("t1")?.clips.count == 2, "the take has no clip")
    }

    @Test func aStudioExportWritesTheFile() async throws {
        let fixture = try await ExportStudioFixture.make()
        let studio = try await fixture.open()

        let faults = try await studio.export(fixture.source, fixture.options, to: fixture.out, replacing: nil).faults

        #expect(faults == [:])
        try await ExportStudioFixture.expectTheExport(at: fixture.out)
        #expect(studio.exportProgress == nil)
    }

    /// The take start cancels the export and waits for its end before its disk check and the
    /// transport change.
    @Test(arguments: StartPath.allCases)
    func aTakeStartDuringAnExportCancelsItFirst(path: StartPath) async throws {
        let fixture = try await ExportStudioFixture.make()
        let hal = TestHAL([fixture.mic])
        let studio = try await fixture.open(hal, seam: ChunkSeam(pause: longChunk))
        let temporaryAtDiskCheck = LockedBox<[String]>()
        let folder = fixture.package.folder.url
        // Only the first call: the disk check of the start. The disk watcher of the take calls
        // it again later, after the export ended.
        studio.environment.freeBytes = { _ in
            if temporaryAtDiskCheck.value == nil {
                temporaryAtDiskCheck.value = try? FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
                    $0.hasSuffix(".tmp")
                }
            }
            return 100_000_000_000
        }
        let (source, options, out) = (fixture.source, fixture.options, fixture.out)
        let export = Task { try await studio.export(source, options, to: out, replacing: nil) }
        // The utility thread makes the temporary file after the job starts. A full suite can
        // hold utility threads for more than 10 s, so the limit is 30 s, as the `Gate` limits.
        await until(limit: .seconds(30), "no temporary file") { (try? fixture.temporaryFiles())?.isEmpty == false }
        var progressAtRecording: Double?? = .none
        withObservationTracking {
            _ = studio.transport
        } onChange: {
            MainActor.assumeIsolated { progressAtRecording = .some(studio.exportProgress) }
        }

        let host = try await start(path, studio, fixture)

        #expect(progressAtRecording == .some(nil), "the export ran when the transport changed")
        if path == .startRecording { #expect(temporaryAtDiskCheck.value == []) }
        #expect(studio.exportProgress == nil)
        await #expect(throws: StudioError.export(.cancelled)) { try await export.value }
        #expect(studio.exportStop == .take, "an agent gets the take text")
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(try fixture.temporaryFiles() == [])
        try await recordAndStop(studio, hal, from: host)
    }

    /// Decision 0049, C9: a cancel of the caller ends the export at its next chunk, with no file.
    @Test func aCancelOfTheCallerEndsTheExport() async throws {
        let fixture = try await ExportStudioFixture.make()
        let gate = Gate(limit: nil)
        defer { gate.open() }
        let studio = try await fixture.open(seam: ChunkSeam(at: [2: { gate.waitOnce() }]))
        let (source, options, out) = (fixture.source, fixture.options, fixture.out)
        let export = Task { try await studio.export(source, options, to: out, replacing: nil) }
        await gate.entered()

        export.cancel()
        gate.open()

        await #expect(throws: StudioError.export(.cancelled)) { try await export.value }
        #expect(studio.exportStop == nil, "a cancel of the caller is not a stop in the window")
        #expect(!FileManager.default.fileExists(atPath: out.path))
        #expect(try fixture.temporaryFiles() == [])
    }

    /// A start that its access check or its route check refuses keeps the export.
    @Test(arguments: StartPath.allCases)
    func aRefusedTakeStartLeavesTheExportRunning(path: StartPath) async throws {
        let fixture = try await ExportStudioFixture.make()
        let gate = Gate(limit: Gate.openLimit)
        let studio = try await fixture.open(seam: ChunkSeam(at: [2: { gate.waitOnce() }]))
        if path == .startRecording {
            studio.environment.microphoneAccess = { .denied }
        } else {
            try studio.edit(ripple: false) { session throws(SessionError) in
                try session.setRoute(Route.device(uid: "mic", channels: .mono(2)), track: "t1")
            }
        }
        let (source, options, out) = (fixture.source, fixture.options, fixture.out)
        let export = Task { try await studio.export(source, options, to: out, replacing: nil) }
        await gate.entered()

        await #expect(throws: StudioError.self) { _ = try await start(path, studio, fixture) }

        #expect(studio.exportProgress != nil)
        gate.open()
        _ = try await export.value
        try await ExportStudioFixture.expectTheExport(at: fixture.out)
    }

    @Test func anExportDuringATakeIsBusy() async throws {
        let fixture = try await ExportStudioFixture.make()
        let hal = TestHAL([fixture.mic])
        let studio = try await fixture.open(hal)
        let host = try await start(.startTake, studio, fixture)

        await #expect(throws: StudioError.busy) {
            try await studio.export(fixture.source, fixture.options, to: fixture.out, replacing: nil)
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.out.path))
        try await recordAndStop(studio, hal, from: host)
    }

    /// A finalize that fails (no `Capture/`) leaves the take pending.
    @Test func anExportWithAPendingTakeIsBusy() async throws {
        let fixture = try await ExportStudioFixture.make()
        let hal = TestHAL([fixture.mic])
        let studio = try await fixture.open(hal)
        let capture = fixture.package.url.appending(path: "Capture")
        studio.environment.beforeFinalize = { try? FileManager.default.removeItem(at: capture) }
        _ = try await start(.startTake, studio, fixture)
        let input = SyntheticInput(hal, "mic")
        input.play(records([sine(seconds: 0.25, rate: 48_000)], layout: [1], rate: 48_000, hostStart: takeStart))
        await input.wait()
        try? await studio.stopRecording()
        try #require(studio.pendingTake != nil)

        await #expect(throws: StudioError.busy) {
            try await studio.export(fixture.source, fixture.options, to: fixture.out, replacing: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.out.path))
    }

    @Test func aSecondExportIsBusy() async throws {
        let fixture = try await ExportStudioFixture.make()
        let gate = Gate(limit: Gate.openLimit)
        let studio = try await fixture.open(seam: ChunkSeam(at: [2: { gate.waitOnce() }]))
        let (source, options, out) = (fixture.source, fixture.options, fixture.out)
        let second = fixture.package.folder.url.appending(path: "second.wav")
        let first = Task { try await studio.export(source, options, to: out, replacing: nil) }
        await gate.entered()

        await #expect(throws: StudioError.busy) {
            try await studio.export(fixture.source, fixture.options, to: second, replacing: nil)
        }
        gate.open()

        _ = try await first.value
        try await ExportStudioFixture.expectTheExport(at: fixture.out)
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }
}

/// Capture comes first across windows (decision 0019, code gate 1 item 2): a take start in
/// studio A ends the export of studio B, and a disk-low check of a take in A ends an export of
/// B to the same volume before it stops the take.
@MainActor
struct StudioExportYieldTests {
    /// Studio B exports its 10 s tone with 1 s chunks, so the export runs until A acts.
    func exportB() async throws -> (Studio, ExportStudioFixture, Task<ExportResult, any Error>) {
        let fixture = try await ExportStudioFixture.make()
        let studio = try await fixture.open(seam: ChunkSeam(pause: longChunk))
        let (source, options, out) = (fixture.source, fixture.options, fixture.out)
        let export = Task { try await studio.export(source, options, to: out, replacing: nil) }
        // A full suite can hold utility threads for more than 10 s, as the `Gate` limits.
        await until(limit: .seconds(30), "B made no temporary file") {
            (try? fixture.temporaryFiles())?.isEmpty == false
        }
        return (studio, fixture, export)
    }

    @Test(arguments: StudioExportTests.StartPath.allCases)
    func aTakeStartEndsTheExportOfAnotherStudio(path: StudioExportTests.StartPath) async throws {
        let a = try await ExportStudioFixture.make()
        let hal = TestHAL([a.mic])
        let studioA = try await a.open(hal)
        let (studioB, b, export) = try await exportB()
        studioA.otherStudios = { [studioB] }

        let host = try await StudioExportTests().start(path, studioA, a)

        await #expect(throws: StudioError.exportYielded) { try await export.value }
        #expect(studioB.exportProgress == nil)
        #expect(!FileManager.default.fileExists(atPath: b.out.path))
        #expect(try b.temporaryFiles() == [])
        try await StudioExportTests().recordAndStop(studioA, hal, from: host)
    }

    /// The free space is low while B has a temporary file next to its target. A take in A starts
    /// first; then B starts its export. The disk check of A ends the export of B, and the take
    /// records on. Control: A with no other studios stops with `.diskLow`.
    @Test(arguments: [true, false])
    func aLowDiskEndsTheExportOfAnotherStudioFirst(knowsB: Bool) async throws {
        let a = try await ExportStudioFixture.make()
        let hal = TestHAL([a.mic])
        let studioA = try await a.open(hal)
        let folderB = LockedBox<URL>()
        studioA.environment.freeBytes = { _ in
            let temporary = folderB.value.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }?
                .contains { $0.hasSuffix(".tmp") }
            return temporary == true ? 0 : 100_000_000_000
        }
        try await studioA.startRecording(armed: ["t1"])
        let (studioB, b, export) = try await exportB()
        if knowsB { studioA.otherStudios = { [studioB] } }
        folderB.value = b.package.folder.url

        await until(limit: .seconds(30), "neither B nor the take ended") {
            studioB.exportProgress == nil || studioA.transport != .recording(take: 1)
        }

        if knowsB {
            await #expect(throws: StudioError.exportYielded) { try await export.value }
            try? await Task.sleep(for: .milliseconds(300))
            #expect(studioA.transport == .recording(take: 1))
            #expect(try b.temporaryFiles() == [])
            try await studioA.stopRecording()
        } else {
            await until(limit: .seconds(30), "the take did not stop") { studioA.transport == .idle }
            #expect(studioA.lastTake?.end == .diskLow)
            studioB.cancelExport()
            _ = try? await export.value
        }
    }

    /// The disk check ends only an export to the volume of the take (decision 0019).
    @Test func sameVolumeComparesTheDevices() throws {
        let folder = try TemporaryFolder()
        #expect(sameVolume(folder.url, FileManager.default.temporaryDirectory))
        #expect(!sameVolume(folder.url, URL(filePath: "/dev")))
    }
}
