import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The raw sweep job at open, of a take that a build before decision 0071 finalized (C5, C17,
/// C19): the job reads the WAV peak off the main actor, appends the finalize record, and removes
/// the CAF.
@MainActor
struct RawSweepTests {
    static let segment = SegmentName(stem: "take1-1-1")!
    static let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 48)!

    /// The steps of the job that the seam saw, and a hold of the job at the step `at`.
    final class Hold: @unchecked Sendable {
        let at: RawSweepStep
        let gate = AsyncGate()
        private let lock = NSLock()
        private var steps: [RawSweepStep] = []

        init(at: RawSweepStep) { self.at = at }

        var seen: [RawSweepStep] { lock.withLock { steps } }

        func step(_ step: RawSweepStep) async {
            lock.withLock { steps.append(step) }
            if step == at { await gate.wait() }
        }
    }

    /// An old take: take 1 with a segment of `seconds` (4 s is 3 WAV blocks) whose float peak is
    /// 4.0, finalized and saved with no sweep, and with no finalize record in its sidecar. Returns
    /// the package and the record that the finalize wrote.
    static func oldTake(seconds: Double = 4) async throws -> (TakePackage, FinalizeRecord) {
        let package = try TakePackage()
        try package.segment(samples: sine(seconds: seconds, rate: 48_000).map { $0 * 4 })
        let url = package.url
        try await offMainActor {
            let outcome = completeTake(of: try Session(contentsOf: url), lock: try PackageLock(url), level: false) {
                session throws(SessionFileError) in try session.write(to: url)
            }
            #expect(outcome.error == nil)
        }
        let record = try #require(try Self.record(in: package))
        let sidecar = package.capture.appending(path: segment.sidecarName)
        let size = try #require(try FileManager.default.attributesOfItem(atPath: sidecar.path)[.size] as? Int)
        try #require(truncate(sidecar.path, off_t(size - Sidecar.encode(record).count)) == 0)
        try #require(try Self.record(in: package) == nil)
        return (package, record)
    }

    static func record(in package: TakePackage) throws -> FinalizeRecord? {
        try Sidecar.decode(Data(contentsOf: package.capture.appending(path: segment.sidecarName)))?.finalized
    }

    static func hasCAF(_ package: TakePackage) -> Bool {
        FileManager.default.fileExists(atPath: package.capture.appending(path: segment.cafName).path)
    }

    @Test func anOpenReturnsBeforeTheSweepReadsTheCAF() async throws {
        let (package, written) = try await Self.oldTake()
        #expect(written.conversionGain != .zero, "the peak of 4.0 gives a clip gain")
        let hold = Hold(at: .block(2))
        defer { hold.gate.open() }

        let studio = try await Studio.open(package.url)
        studio.environment.beforeRawStep = { await hold.step($0) }
        await hold.gate.entered()

        #expect(Self.hasCAF(package), "the job holds at block 2 of the WAV read with the CAF")
        #expect(try Self.record(in: package) == nil, "no record before the read ends")
        hold.gate.open()
        await studio.rawSweep

        #expect(!Self.hasCAF(package), "the sweep removes the CAF of the old take")
        let record = try #require(try Self.record(in: package))
        #expect(record.cafFrames == written.cafFrames && record.sourceRate == written.sourceRate)
        #expect(abs(record.conversionGain.dB - written.conversionGain.dB) < 1e-4, "the gain of the finalize")
        await studio.settle()
    }

    /// C5: the removal of an old take flushes its WAV and `Clips/` before the record append. A WAV
    /// that does not flush keeps the CAF with no record, and the journal has one `raw` line.
    @Test func anOldTakeWhoseWAVDoesNotFlushKeepsItsCAF() async throws {
        let (package, _) = try await Self.oldTake()
        let logs = package.folder.url.appending(path: "logs")
        let log = startLog(in: logs)
        let studio = try await Studio.open(package.url, log: log)
        studio.environment.rawFlush = { $0.hasSuffix(".wav") ? EIO : fullFlush(path: $0) }

        await studio.rawSweep

        #expect(Self.hasCAF(package), "a WAV that does not flush keeps the CAF")
        #expect(try Self.record(in: package) == nil, "no record append before the WAV flush")
        let raw = TakeLogTests.lines(log, in: logs).filter { $0.contains("\traw\t") }
        #expect(raw.count == 1 && raw.first?.contains("errno=\(EIO)") == true, "raw lines: \(raw)")
        await studio.settle()
    }

    /// C17: a close during a blocked WAV read returns only after the job ends, and the job reads
    /// no block after the one that it held.
    @Test func aCloseDuringABlockedReadEndsTheJobAfterThatBlock() async throws {
        let (package, _) = try await Self.oldTake(seconds: 6)
        let hold = Hold(at: .block(2))
        defer { hold.gate.open() }
        let studio = try await Studio.open(package.url)
        studio.environment.beforeRawStep = { await hold.step($0) }
        await hold.gate.entered()
        let settle = Task { await studio.settle() }
        await until(limit: .seconds(10), "the settle does not begin") { studio.settling }
        try await Task.sleep(for: .milliseconds(100))
        #expect(studio.settling, "the settle waits for the held job")

        hold.gate.open()
        await settle.value

        #expect(studio.rawSweepJob.task == nil)
        #expect(!hold.seen.contains(.block(3)), "steps: \(hold.seen)")
        #expect(Self.hasCAF(package))
    }

    /// C17: a take start during a blocked WAV read stops the job after that block. The CAF of the
    /// old take stays during the take, and the sweep at the end of that take removes it.
    @Test func aTakeStartDuringABlockedReadStopsTheJob() async throws {
        let (package, _) = try await Self.oldTake(seconds: 6)
        let (studio, hal) = try await Self.armed(package)
        let hold = Hold(at: .block(2))
        defer { hold.gate.open() }
        studio.environment.beforeRawStep = { await hold.step($0) }
        await hold.gate.entered()
        let start = Task { try await Self.start(studio, recorded: false) }
        await until(limit: .seconds(10), "the take start does not begin") { studio.isStarting }

        hold.gate.open()
        try await start.value

        #expect(!hold.seen.contains(.block(3)), "steps: \(hold.seen)")
        #expect(Self.hasCAF(package), "the old take keeps its CAF during the take")
        try await Self.stop(studio, hal)
        await studio.rawSweep
        #expect(!Self.hasCAF(package), "the sweep at the take end removes the CAF of the old take")
        await studio.settle()
    }

    /// C17: a job that the seam holds at `.turn` while a take start waits for it asks for no turn
    /// after the release, and the start returns within the limit. `recorded` starts the take with
    /// `startRecording` (`startSteps`), else with `startTake`.
    @Test(arguments: [false, true]) func aTakeStartDuringAHeldTurnReturns(recorded: Bool) async throws {
        let (package, _) = try await Self.oldTake()
        let (studio, hal) = try await Self.armed(package)
        let hold = Hold(at: .turn)
        defer { hold.gate.open() }
        studio.environment.beforeRawStep = { await hold.step($0) }
        await hold.gate.entered()
        let done = StepCounter()
        let start = Task {
            try await Self.start(studio, recorded: recorded)
            _ = done.next()
        }
        await until(limit: .seconds(10), "the take start does not begin") { studio.isStarting }
        let turns = studio.writesTaken

        hold.gate.open()
        await until(limit: .seconds(10), "the take start does not return") { done.calls == 1 }
        guard done.calls == 1 else { return }
        try await start.value

        #expect(studio.writesTaken == turns + 1, "only the start takes a turn")
        #expect(Self.hasCAF(package), "the held job removes no CAF")
        try await Self.stop(studio, hal)
        await studio.settle()
    }

    /// C17: two studios whose jobs the seam holds at `.turn`, with a take start in each at the same
    /// time. Each start stops the jobs of both studios, and both starts return within the limit.
    @Test func twoTakeStartsDuringHeldTurnsReturn() async throws {
        let packages = [try await Self.oldTake().0, try await Self.oldTake().0]
        var studios: [(studio: Studio, hal: TestHAL, hold: Hold)] = []
        for package in packages {
            let (studio, hal) = try await Self.armed(package)
            let hold = Hold(at: .turn)
            studio.environment.beforeRawStep = { await hold.step($0) }
            studios.append((studio, hal, hold))
        }
        defer { for entry in studios { entry.hold.gate.open() } }
        let (first, second) = (studios[0].studio, studios[1].studio)
        first.otherStudios = { [weak second] in second.map { [$0] } ?? [] }
        second.otherStudios = { [weak first] in first.map { [$0] } ?? [] }
        for entry in studios { await entry.hold.gate.entered() }
        let done = StepCounter()
        let starts = studios.map { entry in
            Task {
                try await Self.start(entry.studio, recorded: false)
                _ = done.next()
            }
        }
        await until(limit: .seconds(10), "the take starts do not begin") { first.isStarting && second.isStarting }

        for entry in studios { entry.hold.gate.open() }
        await until(limit: .seconds(10), "the take starts do not return") { done.calls == 2 }
        guard done.calls == 2 else { return }
        for start in starts { try await start.value }

        #expect(packages.allSatisfy(Self.hasCAF), "the held jobs remove no CAF")
        for entry in studios { try await Self.stop(entry.studio, entry.hal) }
        for entry in studios { await entry.studio.settle() }
    }

    /// Opens `package` with track t1 routed to `mic` on a test HAL.
    static func armed(_ package: TakePackage) async throws -> (Studio, TestHAL) {
        var session = try Session(contentsOf: package.url)
        try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try session.write(to: package.url)
        let studio = try await Studio.open(package.url)
        let hal = TestHAL([Self.mic])
        studio.environment = .test(hal)
        return (studio, hal)
    }

    /// Starts a take on t1 at the session end.
    static func start(_ studio: Studio, recorded: Bool) async throws {
        let end = studio.session.end
        if recorded {
            try await studio.startRecording(armed: ["t1"], playhead: end)
        } else {
            _ = try await studio.startTake(armed: ["t1"], devices: [mic], playhead: end, hostTimeNanos: takeStart)
        }
    }

    /// Plays 1 s of input to the take of `studio` and stops it.
    static func stop(_ studio: Studio, _ hal: TestHAL) async throws {
        let start = try #require(studio.session.recording?.takeStartHostTimeNanos)
        let input = SyntheticInput(hal, "mic")
        input.play(records([sine(seconds: 1, rate: 48_000)], layout: [1], rate: 48_000, hostStart: start + 1_000_000))
        await input.wait()
        try await studio.stopRecording()
    }
}
