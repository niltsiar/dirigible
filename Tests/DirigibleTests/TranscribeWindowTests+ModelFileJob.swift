import AppKit
import DirigibleTimeline
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

#if DEBUG
    /// The jobs of a model file of the user in the session window (decision 0065 D8, C10, C27,
    /// C28): Choose Model File... of the no-data alert, Locate... of a job that fails because of
    /// the file, and the keep of a passed check whatever the end of the job.
    extension TranscribeWindowTests {
        /// The languages of the engine calls.
        typealias EngineCalls = OSAllocatedUnfairLock<[WhisperLanguage]>

        /// An engine part that adds its language to `calls`, then fails with `error` or gives `words`.
        static func recording(_ calls: EngineCalls, error: TranscribeError? = nil) -> TranscribeEngine {
            let words = Self.words
            return { _, language, count, _, _, _, _ throws(TranscribeError) in
                calls.withLock { $0.append(language) }
                if let error { throw error }
                return Transcription(pieces: [words] + Array(repeating: [], count: max(0, count - 1)), language: "es")
            }
        }

        /// The request of an alert with a button that opens the open panel.
        static func pickRequest(of alert: WindowAlert) -> TranscribeRequest? {
            switch alert {
            case .transcribeFile(_, let request), .transcribeNoData(_, let request): request
            default: nil
            }
        }

        /// A kept "abc" file whose record matches when `passed`, else a kept file with no record.
        static func keep(_ window: FileWindow, passed: Bool) throws -> KeptModelFile {
            let kept = KeptModelFile(
                url: window.file, status: try #require(FileStatus(of: window.file)),
                passed: passed ? PassedModelFile(sha256: abc, facts: tiny) : nil)
            kept.store(for: window.choice, in: window.defaults)
            return kept
        }

        /// The sheet on t2 with `entry` and Spanish, started after `beforeStart`.
        func startSheet(_ window: FileWindow, _ entry: ModelEntry, beforeStart: () throws -> Void = {}) async throws {
            window.model.timeline.selection = .range(Marks(tracks: ["t2"]))
            window.model.run(.transcribe)
            await window.model.transcribe.keptTask?.value
            window.model.selectModel(entry)
            var draft = try #require(window.model.transcribe.draft)
            draft.language = .code("es")
            try beforeStart()
            window.model.startTranscribe(draft)
        }

        /// The alert of the job, after its end.
        func jobAlert(_ window: FileWindow) async throws -> WindowAlert {
            await window.model.transcribe.task?.value
            return try #require(window.model.alert)
        }

        /// The button of the alert: SwiftUI closes the alert, then the open panel opens.
        func press(_ window: FileWindow, _ request: TranscribeRequest, picks: Picks) async {
            window.model.alert = nil
            window.model.startWithPickedFile(request)
            await until("the panel closes") { picks.count == 1 }
            await window.model.transcribe.task?.value
        }

        /// C3 (b): Locate... or Choose Model File... on a studio that became busy while the panel was
        /// open starts nothing: the busy alert shows, no words are added, and the other job keeps running.
        @Test func pickedModelFileOnABusyStudioShowsTheBusyAlert() async throws {
            let picks = Picks([])
            let calls = EngineCalls(initialState: [])
            let window = try await openFile(
                { try Self.passing($0, ran: $0.appending(path: "ran")) }, picks: picks, engine: Self.recording(calls))
            let before = window.studio.session
            let request = TranscribeRequest(
                track: "t2", trackName: "t2", language: .code("es"), choice: .code("es"), model: .catalog(.base))
            for importing in [false, true] {
                let name = importing ? "an agent clip render" : "an agent level"
                let flags = ImportFlags()
                window.studio.transport =
                    importing ? .importing(ImportRun(name: "agent", kind: .clipRender, flags: flags)) : .leveling
                let busy = window.studio.transport
                picks.urls = [window.file]
                picks.count = 0

                await press(window, request, picks: picks)

                #expect(window.model.alert == .error(.busy), "\(name): \(String(describing: window.model.alert))")
                #expect(window.model.transcribe.job == nil && calls.withLock { $0 }.isEmpty, "\(name): a job ran")
                #expect(spoken(window.studio).isEmpty && window.studio.session == before, "\(name): words added")
                #expect(window.studio.transport == busy && flags.isCancelled == false, "\(name): the other job changed")
                window.model.alert = nil
            }
            window.studio.transport = .idle
            await window.model.close()
        }

        /// C27: the no-data alert has the hint text and Choose Model File... (a). The button and a
        /// file that passes start one job with the same track and language, the helper runs once,
        /// and the file is kept (b). A Cancel in the panel starts no job and keeps no file (c).
        @Test(arguments: [true, false]) func theNoDataAlertStartsTheRequestWithAPickedFile(pick: Bool) async throws {
            let ran = folder.url.appending(path: "ran-\(UUID().uuidString)")
            let calls = EngineCalls(initialState: [])
            let picks = Picks([])
            let window = try await openFile(
                { try Self.passing($0, ran: ran) }, picks: picks, engine: Self.recording(calls))
            picks.urls = [pick ? window.file : nil]
            window.studio.environment.modelStore = WhisperModelStore(
                folder: window.folder.appending(path: "Models"),
                load: { _ in AsyncThrowingStream { $0.finish(throwing: URLError(.timedOut)) } })
            try await startSheet(window, .catalog(.smallQ51))

            let alert = try await jobAlert(window)
            let error = StudioError.transcription(.modelDownloadNoData(host: "huggingface.co"))
            let request = try #require(Self.pickRequest(of: alert))
            #expect(alert == .transcribeNoData(error, request) && alert.text == L10n.message(for: error))
            #expect(alert.pickButton == .sheetTranscribeChoose)
            #expect(request.track == "t2" && request.language == .code("es") && request.model == .catalog(.smallQ51))
            await press(window, request, picks: picks)

            if pick {
                #expect(calls.withLock { $0 } == [.code("es")] && spoken(window.studio) == Self.words.map(\.text))
                #expect(Self.runs(ran) == 1)
                await until("the file is kept") {
                    window.kept()?.passed
                        == PassedModelFile(sha256: Self.abc, facts: Self.tiny)
                }
            } else {
                #expect(window.model.transcribe.job == nil && calls.withLock { $0 }.isEmpty && Self.runs(ran) == 0)
                #expect(window.kept() == nil)
            }
            await window.model.close()
        }

        /// C28 (a), (c): a kept file deleted after the sheet open gives Locate...; Locate... and a
        /// file that passes start one job with the same track and language, the helper runs once,
        /// and the new file is kept.
        @Test func aDeletedKeptFileGivesLocateAndThePickedFileIsKept() async throws {
            let ran = folder.url.appending(path: "ran-\(UUID().uuidString)")
            let calls = EngineCalls(initialState: [])
            let picks = Picks([])
            let window = try await openFile(
                { try Self.passing($0, ran: ran) }, picks: picks, engine: Self.recording(calls))
            let new = window.folder.appending(path: "new.bin")
            try Data("abc".utf8).write(to: new)
            picks.urls = [new]
            let kept = try Self.keep(window, passed: true)
            try await startSheet(window, .file) { try FileManager.default.removeItem(at: window.file) }

            let alert = try await jobAlert(window)
            let request = try #require(Self.pickRequest(of: alert))
            #expect(alert.pickButton == .alertTranscribeLocate)
            #expect(alert.text == L10n.errorTranscribeFileMissing.format("user.bin"))
            #expect(request.track == "t2" && request.model == .file(window.file, passed: kept.passed))
            await press(window, request, picks: picks)

            #expect(calls.withLock { $0 } == [.code("es")] && spoken(window.studio) == Self.words.map(\.text))
            #expect(Self.runs(ran) == 1)
            await until("the new file is kept") { window.kept()?.path == new.path }
            await window.model.close()
        }

        /// C28 (b), (d): a kept file that the helper refuses gives Locate..., and the failed check
        /// keeps no record; Locate... and a Cancel start no job, and the kept file does not change.
        @Test func aRefusedKeptFileGivesLocateAndACancelStartsNothing() async throws {
            let ran = folder.url.appending(path: "ran-\(UUID().uuidString)")
            let calls = EngineCalls(initialState: [])
            let picks = Picks([nil])
            let window = try await openFile(
                { try Self.refusing($0, ran: ran) }, picks: picks, engine: Self.recording(calls))
            let kept = try Self.keep(window, passed: false)
            try await startSheet(window, .file)

            let alert = try await jobAlert(window)
            let request = try #require(Self.pickRequest(of: alert))
            #expect(alert.pickButton == .alertTranscribeLocate && Self.runs(ran) == 1)
            await press(window, request, picks: picks)

            #expect(window.model.transcribe.job == nil && calls.withLock { $0 }.isEmpty && Self.runs(ran) == 1)
            #expect(window.kept() == kept)
            await window.model.close()
        }

        enum Fault: CaseIterable { case helperMissing, helperNotStarted, engine, downloadAfterOneByte }

        /// C27 (d), C28 (e): faults of the install, the audio, or a download that got data give the
        /// alert with OK only.
        @Test(arguments: Fault.allCases) func aFaultThatIsNotTheFileGivesOKOnly(fault: Fault) async throws {
            let ran = folder.url.appending(path: "ran-\(UUID().uuidString)")
            let window = try await openFile(
                { try Self.passing($0, ran: ran) }, picks: Picks([]),
                engine: Self.recording(EngineCalls(initialState: []), error: fault == .engine ? .engine(code: 7) : nil))
            _ = try Self.keep(window, passed: false)
            switch fault {
            case .helperMissing, .helperNotStarted:
                let error: ModelFileCheckError =
                    fault == .helperMissing
                    ? .helperMissing(path: "/missing")
                    : .helperNotStarted(path: "/helper", domain: "NSPOSIXErrorDomain", code: 1)
                window.studio.environment.checkModelFile = { _, _, _ throws(ModelFileCheckError) in throw error }
            case .engine: break
            case .downloadAfterOneByte:
                window.studio.environment.modelStore = WhisperModelStore(
                    folder: window.folder.appending(path: "Models"),
                    load: { _ in
                        AsyncThrowingStream {
                            $0.yield(Data([1]))
                            $0.finish(throwing: URLError(.timedOut))
                        }
                    })
            }
            try await startSheet(window, fault == .downloadAfterOneByte ? .catalog(.smallQ51) : .file)

            let alert = try await jobAlert(window)
            #expect(alert.pickButton == nil)
            if case .error = alert {} else { Issue.record("\(alert) is no plain error alert") }
            await window.model.close()
        }

        /// C10: an engine that fails at once after a passed check. The window keeps the file from
        /// the `.checked` stage, which can arrive after the job end, and the next job runs no helper.
        @Test func anEngineErrorAfterAPassedCheckKeepsTheFile() async throws {
            let ran = folder.url.appending(path: "ran-\(UUID().uuidString)")
            let calls = EngineCalls(initialState: [])
            let window = try await openFile(
                { try Self.passing($0, ran: ran) }, picks: Picks([]),
                engine: Self.recording(calls, error: .engine(code: 7)))
            window.model.start(
                TranscribeRequest(
                    track: "t2", trackName: "t2", language: .code("es"), choice: .code("es"),
                    model: .file(window.file, passed: nil)))

            #expect(try await jobAlert(window) == .error(.transcription(.engine(code: 7))))
            let record = PassedModelFile(sha256: Self.abc, facts: Self.tiny)
            await until("the file is kept") { window.kept()?.passed == record }
            // With no kept file, the next sheet starts a catalog download that never ends.
            try #require(window.kept()?.passed == record)
            window.model.alert = nil
            try await startSheet(window, .file)
            _ = try await jobAlert(window)

            #expect(Self.runs(ran) == 1 && calls.withLock { $0 }.count == 2)
            await window.model.close()
        }
    }
#endif
