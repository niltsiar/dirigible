import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

#if DEBUG
    /// The stops of `Studio.transcribe` (decision 0065 D5): Cancel, window close, task cancel (C10),
    /// a take start in any studio (C11), one job per app (C12), and the activity (C26).
    @MainActor
    struct StudioTranscribeStopTests {
        typealias T = StudioTranscribeTests

        enum Stop: CaseIterable { case banner, close, task }

        /// A loader that gives 1 MB of the model and then holds.
        static func stalled() -> HeldLoader { HeldLoader(Data(count: 2 << 20)) }

        /// Waits until the job wrote the first chunk of its download.
        static func downloading(_ studio: Studio) async {
            let file = studio.environment.modelStore.folder.appending(path: WhisperModel.base.fileName + ".download")
            await until(limit: .seconds(10), "the download started") { fileSize(file) ?? 0 > 0 }
        }

        /// C10: the banner Cancel, a window close, and a task cancel each end the job and write nothing.
        @Test(arguments: Stop.allCases) func aCancelEndsTheJobAndWritesNothing(stop: Stop) async throws {
            let fixture = try await ExportStudioFixture.make()
            let gate = Gate(limit: Gate.openLimit)
            let studio = try await T.open(fixture.package, engine: T.engine(gate: gate))
            let before = (studio.session, T.xml(fixture.package))
            let job = T.job(studio)
            await gate.entered()

            var closing: Task<Void, Never>?
            switch stop {
            case .banner: studio.cancelTranscription()
            case .close: closing = Task { await studio.settle() }
            case .task: job.cancel()
            }
            if stop == .close {
                await until(limit: .seconds(10), "settle ended the job") { studio.transcribing?.run.stop.isSet == true }
            }
            gate.open()

            #expect(await job.value.failure == .transcriptionCancelled)
            await closing?.value
            #expect(studio.session == before.0 && T.xml(fixture.package) == before.1)
            await studio.settle()
        }

        /// C10: a window close during a download stall returns before the loader ends the stream, the
        /// engine part never runs, and the model folder holds no file.
        @Test func aWindowCloseDuringADownloadStallReturns() async throws {
            let fixture = try await ExportStudioFixture.make()
            let record = EngineRecord()
            let loader = Self.stalled()
            let studio = try await T.open(
                fixture.package, engine: T.engine(record: record), model: false, load: loader.load)
            let job = T.job(studio)
            await Self.downloading(studio)
            // Other suites hold the main actor that settle needs. So the limit runs off the main actor for
            // Gate.openLimit, and the test ends the stream only when settle waits for that end.
            let endedByTest = StopSwitch()
            let limit = Task { @concurrent in
                try await Task.sleep(for: Gate.openLimit)
                endedByTest.set()
                loader.end()
            }
            defer { limit.cancel() }

            let start = ContinuousClock.now
            await studio.settle()
            let took = ContinuousClock.now - start

            #expect(!endedByTest.isSet, "settle returned before the test ended the stream (\(took))")
            #expect(await job.value.failure == .transcriptionCancelled)
            #expect(record.calls == 0)
            #expect(try fileNames(studio.environment.modelStore.folder) == [])
        }

        /// C10: a stub on the GCD thread of the job calls the abort callback of whisper.cpp with the
        /// flag of the job until it returns true; a banner Cancel and a window close each end it.
        @Test(arguments: [Stop.banner, .close])
        func aBannerCancelAndAWindowCloseEndAStubThatReadsTheCallback(stop: Stop) async throws {
            let fixture = try await ExportStudioFixture.make()
            let (record, endedByCallback, endedByTest) = (EngineRecord(), StopSwitch(), StopSwitch())
            let stub: TranscribeEngine = { _, _, _, _, _, flag, _ throws(TranscribeError) in
                record.add(qos: qos_class_self(), samples: 0)
                while !flag.abortCallback(flag.userData) {
                    guard !endedByTest.isSet else { return Transcription(pieces: [], language: "es") }
                    usleep(1_000)
                }
                endedByCallback.set()
                return nil
            }
            let studio = try await T.open(fixture.package, engine: stub)
            let job = T.job(studio)
            await until(limit: .seconds(10), "the stub runs") { record.calls == 1 }
            // The limit starts at the stop and runs off the main actor, so only a callback that stays
            // false ends the stub here.
            let limit = Task { @concurrent in
                try await Task.sleep(for: Gate.openLimit)
                endedByTest.set()
            }
            defer { limit.cancel() }

            switch stop {
            case .banner: studio.cancelTranscription()
            default: await studio.settle()
            }

            #expect(await job.value.failure == .transcriptionCancelled)
            #expect(endedByCallback.isSet, "the abort callback ended the stub, not its limit")
            await studio.settle()
        }

        /// C11 a and b: a take start in the studio of the job or in a second studio ends the job with
        /// `.transcriptionYielded`, the job writes nothing, and the take records.
        @Test(arguments: [false, true]) func aTakeStartYieldsTheJob(second: Bool) async throws {
            let taking = try await ExportStudioFixture.make()
            let hal = TestHAL([taking.mic])
            let gate = Gate(limit: Gate.openLimit)
            let other = try await ExportStudioFixture.make()
            let jobStudio = try await T.open(
                second ? other.package : taking.package, hal: hal, engine: T.engine(gate: gate))
            let takeStudio = second ? try await taking.open(hal) : jobStudio
            if second { takeStudio.otherStudios = { [jobStudio] } }
            let xml = T.xml(other.package)
            let job = T.job(jobStudio)
            await gate.entered()

            let host = try await StudioExportTests().start(.startTake, takeStudio, taking)
            gate.open()

            #expect(await job.value.failure == .transcriptionYielded)
            #expect(jobStudio.session.transcripts.isEmpty)
            if second { #expect(T.xml(other.package) == xml) }
            try await StudioExportTests().recordAndStop(takeStudio, hal, from: host)
            await jobStudio.settle()
            await takeStudio.settle()
        }

        /// C11 c: a take start after the engine returned and before the end edit ends the job.
        @Test func aTakeStartBeforeTheEndEditYieldsTheJob() async throws {
            let fixture = try await ExportStudioFixture.make()
            let hal = TestHAL([fixture.mic])
            let studio = try await T.open(fixture.package, hal: hal)
            let started = AsyncGate()
            started.open()
            studio.environment.transcribeWorkDone = { @MainActor in
                _ = try? await studio.startTake(armed: ["t1"], devices: [fixture.mic], hostTimeNanos: takeStart)
                await started.wait()
            }

            #expect(await T.job(studio).value.failure == .transcriptionYielded)
            await started.entered()
            #expect(studio.session.transcripts.isEmpty)
            try await StudioExportTests().recordAndStop(studio, hal, from: takeStart)
            await studio.settle()
        }

        /// C11 d: a job start during a take in this studio or in a second studio throws `.busy` and
        /// starts nothing.
        @Test(arguments: [false, true]) func aJobStartDuringATakeIsBusy(second: Bool) async throws {
            let taking = try await ExportStudioFixture.make()
            let hal = TestHAL([taking.mic])
            let record = EngineRecord()
            let other = try await ExportStudioFixture.make()
            let jobStudio = try await T.open(
                second ? other.package : taking.package, hal: hal, engine: T.engine(record: record))
            let takeStudio = second ? try await taking.open(hal) : jobStudio
            if second { jobStudio.otherStudios = { [takeStudio] } }
            let host = try await StudioExportTests().start(.startTake, takeStudio, taking)

            #expect(await T.job(jobStudio).value.failure == .busy)

            #expect(record.calls == 0 && jobStudio.readRuns.isEmpty)
            try await StudioExportTests().recordAndStop(takeStudio, hal, from: host)
            await jobStudio.settle()
            await takeStudio.settle()
        }

        /// C11 e: a take start in a second studio during a download stall ends the job; the engine part
        /// never runs, the model folder holds no file, and the take records.
        @Test func aTakeInASecondStudioEndsTheDownloadStage() async throws {
            let taking = try await ExportStudioFixture.make()
            let hal = TestHAL([taking.mic])
            let other = try await ExportStudioFixture.make()
            let (record, loader) = (EngineRecord(), Self.stalled())
            let jobStudio = try await T.open(
                other.package, engine: T.engine(record: record), model: false, load: loader.load)
            let takeStudio = try await taking.open(hal)
            takeStudio.otherStudios = { [jobStudio] }
            let job = T.job(jobStudio)
            await Self.downloading(jobStudio)

            let host = try await StudioExportTests().start(.startTake, takeStudio, taking)

            #expect(await job.value.failure == .transcriptionYielded)
            #expect(record.calls == 0)
            #expect(try fileNames(jobStudio.environment.modelStore.folder) == [])
            try await StudioExportTests().recordAndStop(takeStudio, hal, from: host)
            await jobStudio.settle()
            await takeStudio.settle()
        }

        /// C12: a second job in the same studio or in a second studio throws `.busy` while one runs.
        @Test func aSecondJobAnywhereIsBusy() async throws {
            let (a, b) = (try await ExportStudioFixture.make(), try await ExportStudioFixture.make())
            let gate = Gate(limit: Gate.openLimit)
            let record = EngineRecord()
            let first = try await T.open(a.package, engine: T.engine(gate: gate, record: record))
            let second = try await T.open(b.package, engine: T.engine(record: record))
            second.otherStudios = { [first] }
            let job = T.job(first)
            await gate.entered()

            #expect(await T.job(first).value.failure == .busy)
            #expect(await T.job(second).value.failure == .busy)
            gate.open()

            #expect(try await job.value.get().kept == 3)
            #expect(record.calls == 1)
            await first.settle()
            await second.settle()
        }

        /// Gate 1 item 5. A task cancel while the end turn waits for a level stores no transcript; the
        /// level keeps its gain.
        @Test func aCancelDuringTheWaitForIdleWritesNoWord() async throws {
            let fixture = try await ExportStudioFixture.make()
            let gate = Gate(limit: Gate.openLimit)
            let studio = try await T.open(fixture.package, engine: T.engine(gate: gate))
            let (saving, done) = (AsyncGate(), AsyncGate())
            done.open()
            studio.environment.transcribeWorkDone = { await done.wait() }
            let save = studio.environment.saveSession
            studio.environment.saveSession = { session, lock throws(SessionFileError) in
                await saving.wait()
                return try await save(session, lock)
            }
            let job = T.job(studio)
            await gate.entered()
            let level = Task { try await studio.level(["c1"], .eachClip) }
            await saving.entered()
            gate.open()
            await done.entered()
            try await Task.sleep(for: .milliseconds(50))

            job.cancel()
            saving.open()

            _ = try await level.value
            #expect(await job.value.failure == .transcriptionCancelled)
            #expect(studio.session.transcripts.isEmpty)
            #expect(studio.session.clip("c1")?.clip.gain != .zero, "the level gain stays")
            await studio.settle()
        }

        /// Gate 1 item 5. A task cancel after the engine part returns, before the end turn, writes
        /// nothing.
        @Test func aCancelAfterTheEnginePartWritesNothing() async throws {
            let fixture = try await ExportStudioFixture.make()
            let studio = try await T.open(fixture.package)
            let done = AsyncGate()
            studio.environment.transcribeWorkDone = { await done.wait() }
            let before = (studio.session, T.xml(fixture.package))
            let job = T.job(studio)
            await done.entered()

            job.cancel()
            done.open()

            #expect(await job.value.failure == .transcriptionCancelled)
            #expect(studio.session == before.0 && T.xml(fixture.package) == before.1)
            await studio.settle()
        }

        /// C26: a job holds one activity from its refusals to each exit (the end, a Cancel, an engine
        /// error), a refused job holds none, and the engine part runs at user-initiated QoS.
        @Test func theJobHoldsOneActivityAndRunsAtUserInitiated() async throws {
            let fixture = try await ExportStudioFixture.make()
            let gate = Gate(limit: Gate.openLimit)
            let record = EngineRecord()
            let studio = try await T.open(fixture.package, engine: T.engine(gate: gate, record: record))
            let reason = studio.environment.transcribeReason
            let assertions = { try StudioRenderTests().assertions(reason) }
            #expect(try assertions() == 0, "control: none before the job")

            let job = T.job(studio)
            await gate.entered()
            #expect(try assertions() == 1, "the job holds the activity")
            #expect(await T.job(studio).value.failure == .busy)
            #expect(try assertions() == 1, "the refused job holds none")
            gate.open()
            _ = try await job.value.get()
            #expect(try assertions() == 0, "the end ended the activity")
            #expect(record.qos == [QOS_CLASS_USER_INITIATED])

            let cancelGate = Gate(limit: Gate.openLimit)
            studio.environment.transcribe = T.engine(gate: cancelGate)
            let cancelled = T.job(studio)
            await cancelGate.entered()
            studio.cancelTranscription()
            cancelGate.open()
            #expect(await cancelled.value.failure == .transcriptionCancelled)
            #expect(try assertions() == 0, "the Cancel ended the activity")

            studio.environment.transcribe = { _, _, _, _, _, _, _ throws(TranscribeError) in throw .engine(code: -1) }
            #expect(await T.job(studio).value.failure == .transcription(.engine(code: -1)))
            #expect(try assertions() == 0, "the engine error ended the activity")
            await studio.settle()
        }
    }

    extension Result {
        /// The error of a failure, else nil.
        var failure: Failure? {
            if case .failure(let error) = self { return error }
            return nil
        }
    }
#endif
