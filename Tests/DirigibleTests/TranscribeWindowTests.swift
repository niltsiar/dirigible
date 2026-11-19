import AppKit
import DirigibleTimeline
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

#if DEBUG
    /// Tools > Transcribe Track... in the session window (decision 0065, C20): the item, the sheet,
    /// the job banner, and the notices. The engine part is scripted, and the model folder is in the
    /// test folder. Two tracks, t1 and t2, each hold 3 s of audio.
    @Suite(.serialized) @MainActor struct TranscribeWindowTests {
        let folder: TemporaryFolder
        let app = AppDelegate(recordings: nil)

        init() throws { folder = try TemporaryFolder() }

        static let words = [
            TimedWord(text: "uno", start: 20, end: 60), TimedWord(text: "dos", start: 70, end: 110),
            TimedWord(text: "tres", start: 120, end: 160),
        ]

        /// An engine part that holds on `hold` after it sets `entered`, then gives `words` as piece 0,
        /// or fails with `error`, or gives nil when the stop flag is set.
        static func engine(
            _ words: [TimedWord] = words, hold: DispatchSemaphore? = nil, entered: LockedFlag = LockedFlag(),
            error: TranscribeError? = nil
        ) -> TranscribeEngine {
            { _, _, count, _, _, stop, _ throws(TranscribeError) in
                entered.value = true
                if let hold { _ = hold.wait(timeout: .now() + 30) }
                if let error { throw error }
                if stop.isSet { return nil }
                return Transcription(pieces: [words] + Array(repeating: [], count: max(0, count - 1)), language: "es")
            }
        }

        func open(_ engine: @escaping TranscribeEngine = engine(), withModel: Bool = true) async throws -> (
            SessionWindow, Studio
        ) {
            let package = try await timelinePackage(in: folder.url, tracks: 2, seconds: 3, audio: true)
            let (model, studio, _, _) = try await openLanes(app, package)
            let models = folder.url.appending(path: "Models")
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
            if withModel {
                FileManager.default.createFile(
                    atPath: models.appending(path: WhisperModel.base.fileName).path, contents: Data([1]))
            }
            model.transcribe.modelFolder = { models }
            studio.environment.transcribe = engine
            studio.environment.transcribeReason = UUID().uuidString
            studio.environment.modelStore = WhisperModelStore(
                folder: models, load: { _ in AsyncThrowingStream { _ in } })
            studio.environment.checkModel = { model, folder in
                CheckedModel.unchecked(model, at: folder.appending(path: model.fileName))
            }
            return (model, studio)
        }

        /// The sheet on `track`, with the language Spanish, started.
        func transcribe(_ model: SessionWindow, track: TrackID = "t2") throws {
            model.timeline.selection = .range(Marks(tracks: [track]))
            model.run(.transcribe)
            var draft = try #require(model.transcribe.draft)
            draft.language = .code("es")
            model.startTranscribe(draft)
        }

        func banners(_ model: SessionWindow) -> [WindowBanner] { ChromeState(model: model).shown.banners }

        func spoken(_ studio: Studio, _ track: TrackID = "t2") -> [String] {
            studio.session.words(on: [track]).map(\.text)
        }

        /// Transcribe on a studio that became busy while the sheet was open (an agent level or an agent
        /// clip render) shows the busy alert, closes the sheet, adds no words, and leaves the other job running.
        @Test func transcribeOnABusyStudioShowsTheBusyAlert() async throws {
            let (model, studio) = try await open()
            let before = studio.session
            for importing in [false, true] {
                let name = importing ? "an agent clip render" : "an agent level"
                studio.transport = .idle
                model.timeline.selection = .range(Marks(tracks: ["t2"]))
                model.run(.transcribe)
                var draft = try #require(model.transcribe.draft, "\(name): the item opened no sheet")
                draft.language = .code("es")
                let flags = ImportFlags()
                studio.transport =
                    importing ? .importing(ImportRun(name: "agent", kind: .clipRender, flags: flags)) : .leveling
                let busy = studio.transport

                model.startTranscribe(draft)
                await until("the job ends") { model.transcribe.job == nil && model.transcribe.task == nil }

                #expect(model.alert == .error(.busy), "\(name): \(String(describing: model.alert))")
                #expect(model.transcribe.draft == nil, "\(name): the sheet shows")
                #expect(spoken(studio).isEmpty && studio.session == before, "\(name): the start changed the session")
                #expect(studio.transport == busy, "\(name): the start changed the other job")
                #expect(flags.isCancelled == false, "\(name): the start cancelled the other job")
                model.alert = nil
            }
            studio.transport = .idle
            await model.close()
        }

        /// C20: the item is on with an idle studio and a track. Control: a take, an open sheet, and
        /// a running job turn it off.
        @Test func menuStateForEachStartState() async throws {
            let hold = DispatchSemaphore(value: 0)
            let entered = LockedFlag()
            let (model, studio) = try await open(Self.engine(hold: hold, entered: entered))
            #expect(model.isOn(.transcribe))
            studio.transport = .recording(take: 1)
            #expect(!model.isOn(.transcribe), "a take")
            studio.transport = .idle
            model.run(.transcribe)
            #expect(model.transcribe.draft != nil && !model.isOn(.transcribe), "the sheet shows")
            model.cancelTranscribeSheet()
            #expect(model.transcribe.draft == nil && model.isOn(.transcribe), "Cancel closes the sheet")
            try transcribe(model)
            await until("the engine holds") { entered.value }
            #expect(!model.isOn(.transcribe) && studio.isIdle, "a running job; the window stays editable")
            hold.signal()
            await until("the job ends") { model.transcribe.job == nil }
            #expect(model.isOn(.transcribe))
            await model.close()
        }

        /// C20: the sheet starts at the selected track; the job shows its request and its banner state;
        /// the words land on that track; a second sheet on it offers Replace with the word count.
        @Test func aJobGivesTheWordsAndTheNextSheetOffersReplace() async throws {
            let hold = DispatchSemaphore(value: 0)
            let entered = LockedFlag()
            let (model, studio) = try await open(Self.engine(hold: hold, entered: entered))
            model.timeline.selection = .range(Marks(tracks: ["t2"]))
            model.run(.transcribe)
            let first = try #require(model.transcribe.draft)
            #expect(first.track == "t2" && first.buttonTitle == .sheetTranscribeStart)
            model.cancelTranscribeSheet()

            try transcribe(model)
            await until("the engine holds") { entered.value }
            let job = try #require(model.transcribe.job)
            #expect(model.transcribe.draft == nil && job.request.track == "t2" && job.request.language == .code("es"))
            #expect(spoken(studio).isEmpty, "the words come at the end")
            hold.signal()
            await until("the job ends") { model.transcribe.job == nil }
            #expect(spoken(studio) == ["uno", "dos", "tres"])
            #expect(model.alert == nil && model.transcribe.notice == nil && studio.canUndo)

            model.run(.transcribe)
            let again = try #require(model.transcribe.draft)
            #expect(again.words == 3 && again.buttonTitle == .sheetTranscribeReplace)
            model.cancelTranscribeSheet()
            await model.close()
        }

        /// A job that keeps no word leaves the old words and the session, and shows the banner.
        @Test func noWordsShowTheBannerAndKeepTheOldWords() async throws {
            let (model, studio) = try await open()
            try transcribe(model)
            await until("the first job ends") { model.transcribe.job == nil }
            let (before, revision) = (studio.session, studio.sessionRevision)

            studio.environment.transcribe = Self.engine([])
            try transcribe(model)
            await until("the second job ends") { model.transcribe.job == nil }
            #expect(studio.session == before && studio.sessionRevision == revision && model.alert == nil)
            let rows = banners(model)
            #expect(rows.map(\.text) == [L10n.transcribeNoWords.text], "\(rows.map(\.text))")
            #expect(rows.first?.kind == .info && rows.first?.announcement != nil)
            await model.close()
        }

        /// C-7: a take start ends the job with the stop banner and no alert. Transcribe Again is off while
        /// a take records, and then runs the same request. The take start is `endReads(.take)`, as
        /// `Studio.record` calls it.
        @Test func aTakeStartShowsTheStopBannerWithTranscribeAgain() async throws {
            let hold = DispatchSemaphore(value: 0)
            let entered = LockedFlag()
            let (model, studio) = try await open(Self.engine(hold: hold, entered: entered))
            try transcribe(model)
            await until("the engine holds") { entered.value }
            studio.endReads(.take)
            hold.signal()
            await until("the job ends") { model.transcribe.job == nil }

            let rows = banners(model)
            #expect(rows.map(\.text) == [L10n.transcribeStopped.text] && rows.first?.kind == .warning)
            #expect(model.alert == nil && spoken(studio).isEmpty)
            guard case .stopped(let request, _, _)? = model.transcribe.notice else {
                Issue.record("notice \(String(describing: model.transcribe.notice))")
                return
            }
            #expect(request.track == "t2" && request.language == .code("es") && request.model == .catalog(.base))

            studio.transport = .recording(take: 1)
            model.transcribeAgain()
            #expect(!model.canTranscribe && model.transcribe.job == nil, "off while a take records")
            studio.transport = .idle
            studio.environment.transcribe = Self.engine()
            model.transcribeAgain()
            #expect(model.transcribe.job?.request == request, "the same job again")
            await until("the second job ends") { model.transcribe.job == nil }
            #expect(spoken(studio) == ["uno", "dos", "tres"] && model.transcribe.notice == nil)
            await model.close()
        }

        /// C-4: the banner Cancel ends the job with no alert, no word, and no notice.
        @Test func theBannerCancelEndsTheJob() async throws {
            let hold = DispatchSemaphore(value: 0)
            let entered = LockedFlag()
            let (model, studio) = try await open(Self.engine(hold: hold, entered: entered))
            let before = studio.session
            try transcribe(model)
            await until("the engine holds") { entered.value }
            model.cancelTranscribe()
            hold.signal()
            await until("the job ends") { model.transcribe.job == nil }
            #expect(studio.session == before && model.alert == nil && model.transcribe.notice == nil)
            #expect(banners(model).isEmpty)
            await model.close()
        }

        /// With no model file the banner shows the download from the start, also before the first
        /// chunk (a stalled download sends no progress); Cancel ends it with no alert and no file.
        @Test func aMissingModelShowsTheDownloadStageAtOnce() async throws {
            let (model, studio) = try await open(withModel: false)
            let before = studio.session
            try transcribe(model)
            #expect(model.transcribe.job?.stage == .download(0) && model.transcribe.job?.fraction == 0)
            model.cancelTranscribe()
            await until("the job ends") { model.transcribe.job == nil }
            #expect(studio.session == before && model.alert == nil && model.transcribe.notice == nil)
            let models = folder.url.appending(path: "Models")
            #expect(try FileManager.default.contentsOfDirectory(atPath: models.path) == [], "no partial file stays")
            await model.close()
        }

        /// A failed job shows an alert, never a banner, and the track is unchanged.
        @Test func anEngineFaultShowsAnAlert() async throws {
            let (model, studio) = try await open(Self.engine(error: .engine(code: 7)))
            let before = studio.session
            try transcribe(model)
            await until("the job ends") { model.transcribe.job == nil }
            #expect(model.alert == .error(.transcription(.engine(code: 7))) && studio.session == before)
            #expect(
                L10n.message(for: StudioError.transcription(.engine(code: 7))) == L10n.errorTranscribeEngine.format(7))
            await model.close()
        }

        /// 0.1 % of the base model: a chunk that does not raise the whole percent after the first.
        static let small = Data(count: WhisperModel.base.byteCount / 1000)

        /// A window with no model file, a download that the test feeds, and hint waits that the
        /// test resumes.
        func openDownload(withModel: Bool = false) async throws -> (
            SessionWindow, Studio, AsyncThrowingStream<Data, any Error>.Continuation, HintWaits
        ) {
            let (model, studio) = try await open(withModel: withModel)
            let (chunks, loader) = AsyncThrowingStream<Data, any Error>.makeStream()
            studio.environment.modelStore = WhisperModelStore(
                folder: studio.environment.modelStore.folder, load: { _ in chunks })
            let waits = HintWaits()
            model.transcribe.hintWait = { await waits.wait($0) }
            return (model, studio, loader, waits)
        }

        /// The button count of the job banner. SwiftUI draws the label, so an `NSButton` here has
        /// no title in the test runner.
        func bannerButtons(_ model: SessionWindow) -> Int {
            let host = NSHostingView(rootView: TranscribeBanner(model: model))
            host.frame = NSRect(x: 0, y: 0, width: 800, height: 80)
            host.layoutSubtreeIfNeeded()
            func buttons(_ view: NSView) -> Int { (view is NSButton ? 1 : 0) + view.subviews.map(buttons).reduce(0, +) }
            return buttons(host)
        }

        /// C20: with no byte at the download start, the hint shows only when the wait ends, names
        /// the host, and leaves the Cancel button alone in the banner.
        @Test func theHintShowsOnlyAfterAWaitWithNoByte() async throws {
            let (model, _, _, waits) = try await openDownload()
            try transcribe(model)
            await until("the first wait") { waits.started == 1 }
            #expect(model.transcribe.job?.hint == nil, "no hint before the wait ends")
            #expect(bannerButtons(model) == 1, "Cancel")

            waits.resumed = 1
            await until("the hint") { model.transcribe.job?.hint != nil }
            #expect(model.transcribe.job?.hint == "huggingface.co" && waits.started == 1)
            #expect(model.transcribe.job?.hintText == L10n.transcribeBannerFirewall.format("huggingface.co"))
            #expect(bannerButtons(model) == 1, "the hint has no button")
            #expect(TranscribeHint.delay == .seconds(10))
            model.cancelTranscribe()
            await until("the job ends") { model.transcribe.job == nil }
            await model.close()
        }

        /// C20 (U19, U27): a chunk under 1 % during the wait gives no hint at its end and a second
        /// wait; that wait gives the hint in the middle of the download; the next chunk, with no new
        /// whole percent, removes it and starts the wait again.
        @Test func aChunkDuringTheWaitWaitsAgainAndTheNextChunkRemovesTheHint() async throws {
            let (model, _, loader, waits) = try await openDownload()
            try transcribe(model)
            await until("the first wait") { waits.started == 1 }
            loader.yield(Self.small)
            await until("the chunk progress") { model.transcribe.job?.stage != .download(0) }
            let stage = model.transcribe.job?.stage

            waits.resumed = 1
            await until("the second wait") { waits.started == 2 }
            #expect(model.transcribe.job?.hint == nil, "a chunk came during the first wait")
            waits.resumed = 2
            await until("the hint") { model.transcribe.job?.hint != nil }
            loader.yield(Self.small)
            await until("the chunk removes the hint") { model.transcribe.job?.hint == nil }
            #expect(model.transcribe.job?.stage == stage, "no progress call removed it")
            await until("the third wait") { waits.started == 3 }
            model.cancelTranscribe()
            await until("the job ends") { model.transcribe.job == nil }
            await model.close()
        }

        /// Code gate 1 item 10: a stalled download that ends with no data is freed with its job. The
        /// armed hint must not hold the download that holds it.
        @Test func aStalledDownloadThatEndsWithNoDataIsFreed() async throws {
            let (model, _, loader, waits) = try await openDownload()
            try transcribe(model)
            await until("the first wait") { waits.started == 1 }
            waits.resumed = 1
            await until("the hint") { model.transcribe.job?.hint != nil }
            weak let download = model.transcribe.download
            #expect(download != nil)

            loader.finish(throwing: URLError(.timedOut))
            await model.transcribe.task?.value

            #expect(model.transcribe.download == nil && model.alert != nil)
            await until("the download is freed") { download == nil }
            await model.close()
        }

        /// C20: the heal path (a catalog file that fails its check) shows the download stage at the
        /// download start and the hint after the wait.
        @Test func theHealPathShowsTheDownloadAndTheHint() async throws {
            let (model, studio, _, waits) = try await openDownload(withModel: true)
            studio.environment.checkModel = { _, _ in nil }
            try transcribe(model)
            await until("the download stage") { model.transcribe.job?.stage == .download(0) }
            await until("the first wait") { waits.started == 1 }
            waits.resumed = 1
            await until("the hint") { model.transcribe.job?.hint == "huggingface.co" }
            model.cancelTranscribe()
            await until("the job ends") { model.transcribe.job == nil }
            await model.close()
        }

        /// C20: a model on disk never starts the wait; a cancel during the wait ends it with the job.
        @Test func noDownloadStartsNoWaitAndACancelEndsTheWait() async throws {
            let (model, studio, _, waits) = try await openDownload(withModel: true)
            try transcribe(model)
            await until("the job ends") { model.transcribe.job == nil }
            #expect(spoken(studio) == ["uno", "dos", "tres"] && waits.started == 0)

            try FileManager.default.removeItem(at: studio.environment.modelStore.folder)
            try transcribe(model)
            await until("the first wait") { waits.started == 1 }
            model.cancelTranscribe()
            await until("the job ends") { model.transcribe.job == nil }
            await until("the job end ends the wait") { waits.ended == 1 }
            #expect(waits.started == 1 && model.alert == nil)
            await model.close()
        }
    }

    /// The hint waits of a window. Wait n holds until `resumed` reaches n or its task is cancelled,
    /// as the sleep of the live wait.
    @MainActor final class HintWaits {
        var started = 0
        var ended = 0
        var resumed = 0

        func wait(_: ContinuousClock.Instant) async {
            started += 1
            let number = started
            defer { ended += 1 }
            let end = ContinuousClock.now + .seconds(87)
            while resumed < number, !Task.isCancelled {
                guard ContinuousClock.now < end else {
                    Issue.record("wait \(number) was not resumed")
                    return
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }
#endif
