import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

#if DEBUG
    /// The Language pop-up of the Transcribe sheet (`selectLanguage`) and the model file of the user
    /// (C19 (g), C25): the model of the new choice, and the stops of the sheet check by a Language
    /// change and by a take start of the window.
    extension TranscribeWindowTests {
        /// The kept file `url` of `language`, with the status of the file, so no sheet hash runs.
        func keepFile(_ url: URL, for language: WhisperLanguage, in window: FileWindow) throws {
            KeptModelFile(
                url: url, status: try #require(FileStatus(of: url)),
                passed: PassedModelFile(sha256: String(repeating: "d", count: 64), facts: Self.tiny)
            ).store(for: language, in: window.defaults)
        }

        /// C19 (g): a Language change selects what a sheet open with the new choice selects. German
        /// remembers More Accurate and keeps no file; Italian has no memory (the language rule);
        /// Spanish remembers More Accurate and keeps file A; French remembers its kept file B.
        @Test func aLanguageChangeSelectsWhatASheetOpenWithThatChoiceSelects() async throws {
            let window = try await openFile({ $0 }, picks: Picks([]))
            let french = window.folder.appending(path: "french.bin")
            try Data("abcd".utf8).write(to: french)
            try keepFile(window.file, for: .code("es"), in: window)
            try keepFile(french, for: .code("fr"), in: window)
            for language in [WhisperLanguage.code("de"), .code("es")] {
                TranscribeModelMemory.remember(.catalog(.smallQ51), for: language, in: window.defaults)
            }
            TranscribeModelMemory.remember(.file, for: .code("fr"), in: window.defaults)
            window.defaults.set("en", forKey: TranscribeDraft.languageKey)
            #expect(try sheet(window).model == .catalog(.base))

            func change(to code: String) async throws -> TranscribeDraft {
                window.model.selectLanguage(.code(code))
                await window.model.transcribe.keptTask?.value
                return try #require(window.model.transcribe.draft)
            }
            #expect(try await change(to: "de").model == .catalog(.smallQ51), "the German memory")
            #expect(try await change(to: "it").model == .catalog(.base), "the language rule")
            let spanish = try await change(to: "es")
            #expect(spanish.model == .catalog(.smallQ51) && spanish.kept?.path == window.file.path)
            let frenchDraft = try await change(to: "fr")
            #expect(frenchDraft.model == .file && frenchDraft.kept?.path == french.path && frenchDraft.request != nil)
            await window.model.close()
        }

        /// C25: a Language change during the sheet check stops the helper, as a Model change does. The
        /// German memory holds its kept file, so that file takes the Model entry, the check line goes,
        /// and the picked file is kept for no choice.
        @Test func aLanguageChangeDuringTheSheetCheckStopsTheCheck() async throws {
            let pidFile = folder.url.appending(path: "pid-\(UUID().uuidString)")
            let picks = Picks([])
            let window = try await openFile(
                {
                    try Self.stub(
                        "echo $$ > '\(pidFile.path)'.tmp; mv '\(pidFile.path)'.tmp '\(pidFile.path)'; exec sleep 30",
                        in: $0)
                }, picks: picks)
            let german = window.folder.appending(path: "german.bin")
            try Data("abcd".utf8).write(to: german)
            try keepFile(german, for: .code("de"), in: window)
            TranscribeModelMemory.remember(.file, for: .code("de"), in: window.defaults)
            let kept = try #require(window.kept(for: .code("de")))
            picks.urls = [window.file]
            _ = try sheet(window)
            window.model.selectModel(.choose)
            await until(limit: .seconds(10), "the helper wrote its PID") {
                FileManager.default.fileExists(atPath: pidFile.path)
            }
            let pid = try #require(pid_t(String(decoding: Data(contentsOf: pidFile), as: UTF8.self).filter(\.isNumber)))

            window.model.selectLanguage(.code("de"))
            await until(limit: .seconds(5), "the helper \(pid) ends") { kill(pid, 0) == -1 && errno == ESRCH }

            await window.model.transcribe.keptTask?.value
            let draft = try #require(window.model.transcribe.draft)
            #expect(draft.model == .file && draft.kept?.path == german.path && draft.check == nil && draft.canStart)
            #expect(window.kept(for: .code("de")) == kept && window.kept(for: .code("es")) == nil)
            await window.model.close()
        }

        /// C25: a take start after a Language change stopped the check gives no take line and no entry
        /// of the old choice. The Spanish sheet starts on its kept file; German keeps no file. The
        /// check ends only when its gate opens, after the take start.
        @Test func aTakeAfterALanguageChangeDuringTheCheckKeepsTheNewModel() async throws {
            let picks = Picks([])
            let window = try await openFile({ $0 }, picks: picks)
            try keepFile(window.file, for: .code("es"), in: window)
            TranscribeModelMemory.remember(.file, for: .code("es"), in: window.defaults)
            let (started, gate) = (
                OSAllocatedUnfairLock(initialState: false), OSAllocatedUnfairLock(initialState: false)
            )
            window.studio.environment.checkModelFile = { _, _, _ throws(ModelFileCheckError) -> CheckedModel in
                started.withLock { $0 = true }
                while !gate.withLock({ $0 }) { usleep(1_000) }
                throw .stopped
            }
            picks.urls = [window.file]
            #expect(try sheet(window).model == .file)
            window.model.selectModel(.choose)
            await until("the check runs") { started.withLock { $0 } }
            let check = window.model.transcribe.checkTask

            window.model.selectLanguage(.code("de"))
            window.studio.endReads(.take)
            gate.withLock { $0 = true }
            await check?.value

            let draft = try #require(window.model.transcribe.draft)
            #expect(draft.model == .catalog(.base) && draft.check == nil && draft.request != nil)
            await window.model.close()
        }

        /// C25 (d): a take start of this window (`startTake`) during the sheet check gives the entry
        /// before the pick and the take line when the start returns. The check result waits on a gate
        /// until after the start, so the window cancels the check before its result comes.
        @Test func aTakeOfThisWindowDuringTheSheetCheckShowsTheTakeLine() async throws {
            let pidFile = folder.url.appending(path: "pid-\(UUID().uuidString)")
            let picks = Picks([])
            let window = try await openFile(
                {
                    try Self.stub(
                        "echo $$ > '\(pidFile.path)'.tmp; mv '\(pidFile.path)'.tmp '\(pidFile.path)'; exec sleep 30",
                        in: $0)
                }, picks: picks, device: "duo")
            let (hal, gate) = (CountingHAL(), OSAllocatedUnfairLock(initialState: false))
            defer { gate.withLock { $0 = true } }
            let check = window.studio.environment.checkModelFile
            var environment = hal.environment
            environment.checkModelFile = { url, passed, stop throws(ModelFileCheckError) in
                defer { while !gate.withLock({ $0 }) { usleep(1_000) } }
                return try check(url, passed, stop)
            }
            window.studio.environment = environment
            picks.urls = [window.file]
            let model = window.model
            let before = try sheet(window).model
            model.selectModel(.choose)
            await until(limit: .seconds(10), "the helper wrote its PID") {
                FileManager.default.fileExists(atPath: pidFile.path)
            }
            let pid = try #require(pid_t(String(decoding: Data(contentsOf: pidFile), as: UTF8.self).filter(\.isNumber)))
            let task = model.transcribe.checkTask

            #expect(await model.startTake(armed: ["t1"], playhead: nil) == .started(take: 1))
            let take = L10n.sheetTranscribeCheckTake.text
            let draft = try #require(model.transcribe.draft)
            #expect(draft.model == before && draft.check == .refused(take) && !draft.isChecking)
            await until(limit: .seconds(5), "the helper \(pid) ends") { kill(pid, 0) == -1 && errno == ESRCH }
            gate.withLock { $0 = true }
            await task?.value
            let late = model.transcribe.draft
            #expect(late?.model == before && late?.check == .refused(take) && window.kept() == nil)
            #expect(window.studio.transport == .recording(take: 1))

            await model.stop()
            await until("the take ends") { window.studio.isIdle }
            await model.close()
        }
    }
#endif
