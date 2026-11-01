import Foundation
import Testing
import os

@testable import DirigibleAudio
@testable import DirigibleCore

#if DEBUG
    /// What a scripted engine part got: the checked model and the language of each call.
    final class ModelRecord: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(model: CheckedModel, language: WhisperLanguage)] = []

        func add(_ model: CheckedModel, _ language: WhisperLanguage) {
            lock.withLock { seen.append((model, language)) }
        }
        var models: [CheckedModel] { lock.withLock { seen.map(\.model) } }
        var languages: [WhisperLanguage] { lock.withLock { seen.map(\.language) } }
    }

    /// The stages of one job, on the main actor.
    @MainActor final class Stages {
        var all: [TranscribeProgress] = []

        var records: [PassedModelFile] {
            all.compactMap {
                if case .checked(let record) = $0 { return record }
                return nil
            }
        }
    }

    /// `Studio.transcribe` with a model file of the user (decision 0065, D8): C10 to C13. The
    /// helper is a stub script that `ModelFileCheck.run` starts through the `checkModelFile` seam.
    @MainActor
    struct StudioTranscribeModelFileTests {
        typealias T = StudioTranscribeTests

        enum Stop: CaseIterable { case takeHere, takeInAnotherStudio, banner, settle }

        /// A scripted engine part that records its model and language and gives the words of
        /// `T.words` in the language that it got (es for `.automatic`).
        static func engine(_ record: ModelRecord) -> TranscribeEngine {
            let words = T.words
            return { model, language, count, _, _, _, _ throws(TranscribeError) in
                record.add(model, language)
                let code = if case .code(let code) = language { code } else { "es" }
                return Transcription(pieces: [words] + Array(repeating: [], count: max(0, count - 1)), language: code)
            }
        }

        /// A helper stub that adds a line to `ran` and passes with the SHA-256 of the file.
        static func passing(_ folder: URL, ran: URL, multilingual: Bool = true) throws -> URL {
            try ModelFileCheckTests.stub(
                "echo run >> '\(ran.path)'; echo \"sha256=$(shasum -a 256 \"$3\" | cut -d' ' -f1) audio_layers=4 "
                    + "text_layers=4 n_mels=80 multilingual=\(multilingual ? "yes" : "no")\"",
                in: folder)
        }

        /// The model file "abc" in the package folder, a studio on `package` whose check starts
        /// `helper`, and the engine part `engine`.
        static func open(
            _ package: MixPackage, helper: URL, hal: TestHAL = TestHAL([]), engine: @escaping TranscribeEngine
        ) async throws -> (Studio, URL) {
            let studio = try await T.open(package, hal: hal, engine: engine)
            studio.environment.checkModelFile = { url, passed, stop throws(ModelFileCheckError) in
                try ModelFileCheck.run(url, helper: helper, passed: passed, stop: stop)
            }
            let file = package.folder.url.appending(path: "user.bin")
            try Data("abc".utf8).write(to: file)
            return (studio, file)
        }

        /// Runs one job on t1 with the file at `url` and gives its result.
        static func job(
            _ studio: Studio, _ url: URL, passed: PassedModelFile? = nil, language: WhisperLanguage = .code("es"),
            stages: Stages = Stages()
        ) -> Task<Result<TranscribeReport, StudioError>, Never> {
            Task {
                do throws(StudioError) {
                    return .success(
                        try await studio.transcribe(
                            track: "t1", language: language, model: .file(url, passed: passed)
                        ) { stages.all.append($0) })
                } catch {
                    return .failure(error)
                }
            }
        }

        static func runs(_ ran: URL) -> Int {
            (try? String(contentsOf: ran, encoding: .utf8))?.split(separator: "\n").count ?? 0
        }

        static let facts = WhisperModelFacts(audioLayers: 4, textLayers: 4, melCount: 80, isMultilingual: true)

        /// C10: the check, then the engine with the checked file; the stages are `.check`, then
        /// `.checked` with the record, then `.transcribe`; the report has the record.
        @Test func aJobWithAUserFileRunsTheCheckThenTheEngine() async throws {
            let fixture = try await ExportStudioFixture.make()
            let (record, stages, ran) = (ModelRecord(), Stages(), fixture.package.folder.url.appending(path: "ran"))
            let helper = try Self.passing(fixture.package.folder.url, ran: ran)
            let (studio, file) = try await Self.open(fixture.package, helper: helper, engine: Self.engine(record))

            let report = try await Self.job(studio, file, stages: stages).value.get()

            let passed = PassedModelFile(sha256: ModelFileCheckTests.abc, facts: Self.facts)
            #expect(record.models == [CheckedModel(source: .file(passed), url: file)])
            #expect(Self.runs(ran) == 1)
            #expect(Array(stages.all.prefix(2)) == [.check, .checked(passed)])
            #expect(stages.all.dropFirst(2).allSatisfy { if case .transcribe = $0 { true } else { false } })
            #expect(report.kept == 3 && report.modelFile == passed)
            await studio.settle()
        }

        /// C10: a passed record with the SHA-256 of the file runs no helper, and the engine gets the
        /// facts of the record; after a 1-byte change, the helper runs once.
        @Test func aSecondJobOnAnUnchangedFileRunsNoHelper() async throws {
            let fixture = try await ExportStudioFixture.make()
            let (record, ran) = (ModelRecord(), fixture.package.folder.url.appending(path: "ran"))
            let helper = try Self.passing(fixture.package.folder.url, ran: ran)
            let (studio, file) = try await Self.open(fixture.package, helper: helper, engine: Self.engine(record))
            let kept = PassedModelFile(
                sha256: ModelFileCheckTests.abc,
                facts: WhisperModelFacts(audioLayers: 32, textLayers: 4, melCount: 128, isMultilingual: true))

            _ = try await Self.job(studio, file, passed: kept).value.get()
            #expect(Self.runs(ran) == 0)
            #expect(record.models.last?.source == .file(kept))

            try Data("abd".utf8).write(to: file)
            _ = try await Self.job(studio, file, passed: kept).value.get()
            #expect(Self.runs(ran) == 1)
            #expect(record.models.count == 2)
            await studio.settle()
        }

        enum End: CaseIterable { case engineError, take }

        /// C10, the job part: an engine error and a take start after a passed check each send
        /// `.checked` with the record before the job throws, and a next job with that record runs no
        /// helper.
        @Test(arguments: End.allCases) func aJobEndAfterAPassedCheckSendsTheRecord(end: End) async throws {
            let fixture = try await ExportStudioFixture.make()
            let hal = TestHAL([fixture.mic])
            let (record, stages, ran) = (ModelRecord(), Stages(), fixture.package.folder.url.appending(path: "ran"))
            let helper = try Self.passing(fixture.package.folder.url, ran: ran)
            let failing: TranscribeEngine = { _, _, _, _, _, _, _ throws(TranscribeError) in throw .engine(code: -1) }
            let (studio, file) = try await Self.open(
                fixture.package, helper: helper, hal: hal, engine: end == .engineError ? failing : Self.engine(record))
            if end == .take {
                studio.environment.modelFileCheckDone = { @MainActor in
                    _ = try? await studio.startTake(armed: ["t1"], devices: [fixture.mic], hostTimeNanos: takeStart)
                }
            }

            let result = await Self.job(studio, file, stages: stages).value

            #expect(result.failure == (end == .take ? .transcriptionYielded : .transcription(.engine(code: -1))))
            let passed = try #require(stages.records.first)
            #expect(passed.sha256 == ModelFileCheckTests.abc && Self.runs(ran) == 1)
            if end == .take {
                try await StudioExportTests().recordAndStop(studio, hal, from: takeStart)
                studio.environment.modelFileCheckDone = {}
            }
            studio.environment.transcribe = Self.engine(record)
            _ = try await Self.job(studio, file, passed: passed).value.get()
            #expect(Self.runs(ran) == 1)
            #expect(record.models.last?.source == .file(passed))
            await studio.settle()
        }

        /// C10: a check that fails sends no `.checked` and runs no engine.
        @Test func aFailedCheckSendsNoRecord() async throws {
            let fixture = try await ExportStudioFixture.make()
            let (record, stages) = (ModelRecord(), Stages())
            let helper = try ModelFileCheckTests.stub(
                "echo 'Error: The model file ends before its last part.' >&2; exit 1", in: fixture.package.folder.url)
            let (studio, file) = try await Self.open(fixture.package, helper: helper, engine: Self.engine(record))

            let result = await Self.job(studio, file, stages: stages).value

            #expect(result.failure == .transcription(.modelFile(.refused("The model file ends before its last part."))))
            #expect(stages.all == [.check] && record.models.isEmpty)
            await studio.settle()
        }

        /// C11: a 1-byte change after the check and before the engine gives `.modelChanged` and no
        /// engine call; with no change, the engine runs.
        @Test(arguments: [true, false]) func aFileThatChangesAfterTheCheckIsRefused(change: Bool) async throws {
            let fixture = try await ExportStudioFixture.make()
            let (record, ran) = (ModelRecord(), fixture.package.folder.url.appending(path: "ran"))
            let helper = try Self.passing(fixture.package.folder.url, ran: ran)
            let (studio, file) = try await Self.open(fixture.package, helper: helper, engine: Self.engine(record))
            if change { studio.environment.modelFileCheckDone = { try? Data("abd".utf8).write(to: file) } }

            let result = await Self.job(studio, file).value

            #expect(result.failure == (change ? .transcription(.modelChanged) : nil))
            #expect(record.models.count == (change ? 0 : 1))
            await studio.settle()
        }

        /// C12: a take start here or in another studio, the banner Cancel, and `settle()` during the
        /// check each end the job, the helper process is gone, and the job writes nothing.
        @Test(arguments: Stop.allCases) func aStopDuringTheCheckEndsTheHelper(stop: Stop) async throws {
            let taking = try await ExportStudioFixture.make()
            let hal = TestHAL([taking.mic])
            let other = try await ExportStudioFixture.make()
            let second = stop == .takeInAnotherStudio
            let package = second ? other.package : taking.package
            let pidFile = package.folder.url.appending(path: "pid")
            let helper = try ModelFileCheckTests.stub(
                "echo $$ > '\(pidFile.path)'.tmp; mv '\(pidFile.path)'.tmp '\(pidFile.path)'; exec sleep 30",
                in: package.folder.url)
            let record = ModelRecord()
            let (studio, file) = try await Self.open(package, helper: helper, hal: hal, engine: Self.engine(record))
            let takeStudio = second ? try await taking.open(hal) : studio
            if second { takeStudio.otherStudios = { [studio] } }
            let before = (studio.session, T.xml(package))
            let job = Self.job(studio, file)
            await until(limit: .seconds(10), "the helper wrote its PID") {
                FileManager.default.fileExists(atPath: pidFile.path)
            }
            let pid = try #require(pid_t(String(decoding: Data(contentsOf: pidFile), as: UTF8.self).filter(\.isNumber)))

            var host: UInt64?
            var closing: Task<Void, Never>?
            switch stop {
            case .takeHere, .takeInAnotherStudio:
                host = try await StudioExportTests().start(.startTake, takeStudio, taking)
            case .banner: studio.cancelTranscription()
            case .settle: closing = Task { await studio.settle() }
            }

            let ended = await job.value
            await closing?.value
            #expect(ended.failure == (host == nil ? .transcriptionCancelled : .transcriptionYielded))
            #expect(kill(pid, 0) == -1 && errno == ESRCH, "the helper \(pid) still runs")
            #expect(record.models.isEmpty && studio.session.transcripts.isEmpty)
            if stop != .takeHere { #expect(studio.session == before.0 && T.xml(package) == before.1) }
            if let host { try await StudioExportTests().recordAndStop(takeStudio, hal, from: host) }
            await studio.settle()
            await takeStudio.settle()
        }

        /// The sheet check of `url` in `studio`: nil when it passes, else its error.
        static func check(_ studio: Studio, _ url: URL) async -> StudioError? {
            do throws(StudioError) {
                _ = try await studio.checkModelFile(url, passed: nil)
                return nil
            } catch {
                return error
            }
        }

        enum CheckStop: CaseIterable { case takeHere, takeInAnotherStudio, settle }

        /// C25: the sheet check is a read run of the studio. A take start here or in another studio
        /// ends it with `.readYielded`, `settle()` ends it with `.readClosed`, and the helper is gone.
        @Test(arguments: CheckStop.allCases) func aTakeStartStopsTheSheetCheck(stop: CheckStop) async throws {
            let taking = try await ExportStudioFixture.make()
            let hal = TestHAL([taking.mic])
            let other = try await ExportStudioFixture.make()
            let second = stop == .takeInAnotherStudio
            let package = second ? other.package : taking.package
            let pidFile = package.folder.url.appending(path: "pid")
            let helper = try ModelFileCheckTests.stub(
                "echo $$ > '\(pidFile.path)'.tmp; mv '\(pidFile.path)'.tmp '\(pidFile.path)'; exec sleep 30",
                in: package.folder.url)
            let (studio, file) = try await Self.open(
                package, helper: helper, hal: hal, engine: Self.engine(ModelRecord()))
            let takeStudio = second ? try await taking.open(hal) : studio
            if second { takeStudio.otherStudios = { [studio] } }
            let check = Task { await Self.check(studio, file) }
            await until(limit: .seconds(10), "the helper wrote its PID") {
                FileManager.default.fileExists(atPath: pidFile.path)
            }
            let pid = try #require(pid_t(String(decoding: Data(contentsOf: pidFile), as: UTF8.self).filter(\.isNumber)))

            var host: UInt64?
            var closing: Task<Void, Never>?
            switch stop {
            case .takeHere, .takeInAnotherStudio:
                host = try await StudioExportTests().start(.startTake, takeStudio, taking)
            case .settle: closing = Task { await studio.settle() }
            }

            #expect(await check.value == (host == nil ? .readClosed : .readYielded))
            await closing?.value
            #expect(kill(pid, 0) == -1 && errno == ESRCH, "the helper \(pid) still runs")
            if let host { try await StudioExportTests().recordAndStop(takeStudio, hal, from: host) }
            await studio.settle()
            await takeStudio.settle()
        }

        /// C25 (f): while another studio records, the sheet check refuses with `.busy` before the
        /// check seam, so no hash and no helper run. Control: after the take stops, the same check
        /// runs the helper once.
        @Test func aCheckDuringATakeInAnotherStudioRunsNothing() async throws {
            let taking = try await ExportStudioFixture.make()
            let hal = TestHAL([taking.mic])
            let other = try await ExportStudioFixture.make()
            let ran = other.package.folder.url.appending(path: "ran")
            let helper = try Self.passing(other.package.folder.url, ran: ran)
            let (studio, file) = try await Self.open(
                other.package, helper: helper, hal: hal, engine: Self.engine(ModelRecord()))
            let seams = OSAllocatedUnfairLock(initialState: 0)
            let seam = studio.environment.checkModelFile
            studio.environment.checkModelFile = { url, passed, stop throws(ModelFileCheckError) in
                seams.withLock { $0 += 1 }
                return try seam(url, passed, stop)
            }
            let takeStudio = try await taking.open(hal)
            studio.otherStudios = { [takeStudio] }
            let host = try await StudioExportTests().start(.startTake, takeStudio, taking)

            #expect(await Self.check(studio, file) == .busy)
            #expect(seams.withLock { $0 } == 0 && Self.runs(ran) == 0)

            try await StudioExportTests().recordAndStop(takeStudio, hal, from: host)
            #expect(await Self.check(studio, file) == nil)
            #expect(seams.withLock { $0 } == 1 && Self.runs(ran) == 1)
            await studio.settle()
            await takeStudio.settle()
        }

        /// C13: an English-only file refuses another language before the engine.
        @Test func anEnglishOnlyFileRefusesAnotherLanguage() async throws {
            let fixture = try await ExportStudioFixture.make()
            let (record, stages, ran) = (ModelRecord(), Stages(), fixture.package.folder.url.appending(path: "ran"))
            let helper = try Self.passing(fixture.package.folder.url, ran: ran, multilingual: false)
            let (studio, file) = try await Self.open(fixture.package, helper: helper, engine: Self.engine(record))

            let result = await Self.job(studio, file, language: .code("es"), stages: stages).value

            #expect(result.failure == .transcription(.languageNotInModel))
            #expect(record.models.isEmpty)
            #expect(stages.records.count == 1, "the check passed, so the record is kept")
            await studio.settle()
        }

        /// C13: an English-only file runs the engine in English for `en` and for `.automatic`, and the
        /// report language is en.
        @Test(arguments: [WhisperLanguage.code("en"), .automatic])
        func anEnglishOnlyFileRunsInEnglish(language: WhisperLanguage) async throws {
            let fixture = try await ExportStudioFixture.make()
            let (record, ran) = (ModelRecord(), fixture.package.folder.url.appending(path: "ran"))
            let helper = try Self.passing(fixture.package.folder.url, ran: ran, multilingual: false)
            let (studio, file) = try await Self.open(fixture.package, helper: helper, engine: Self.engine(record))

            let report = try await Self.job(studio, file, language: language).value.get()

            #expect(record.languages == [.code("en")])
            #expect(report.language == "en")
            await studio.settle()
        }

        /// C20, C21: on the heal path (a catalog file that fails its check) the job reports the
        /// download stage at the download start, before any chunk; a timeout with no byte ends the
        /// job with the no-data error and the host.
        @Test func theHealPathReportsTheDownloadAtItsStart() async throws {
            let fixture = try await ExportStudioFixture.make()
            let (chunks, loader) = AsyncThrowingStream<Data, any Error>.makeStream()
            let studio = try await T.open(fixture.package, load: { _ in chunks })
            studio.environment.checkModel = { _, _ in nil }
            let stages = Stages()
            let job = Task {
                do throws(StudioError) {
                    _ = try await studio.transcribe(track: "t1", language: .code("es"), model: .catalog(.base)) {
                        stages.all.append($0)
                    }
                    return StudioError?.none
                } catch {
                    return error
                }
            }

            await until(limit: .seconds(30), "the download stage") { !stages.all.isEmpty }
            #expect(stages.all == [.download(0)])
            loader.finish(throwing: URLError(.timedOut))
            #expect(await job.value == .transcription(.modelDownloadNoData(host: "huggingface.co")))
            await studio.settle()
        }
    }
#endif
