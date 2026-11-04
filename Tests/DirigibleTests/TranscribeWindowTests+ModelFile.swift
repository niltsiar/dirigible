import AppKit
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

#if DEBUG
    /// The model file of the user in the session window (decision 0065 D8, C10, C17, C18, C24, C25,
    /// C27, C28): the open panel, the sheet check with stub helpers, the kept file in the defaults,
    /// the stops of the check, and the buttons of the job alerts. The model file is "abc".
    extension TranscribeWindowTests {
        static let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        nonisolated static let tiny = WhisperModelFacts(
            audioLayers: 4, textLayers: 4, melCount: 80, isMultilingual: true)

        /// The open panel of the tests: it gives the next URL, nil for Cancel.
        @MainActor final class Picks {
            var urls: [URL?]
            var count = 0
            init(_ urls: [URL?]) { self.urls = urls }
            func next() -> URL? {
                count += 1
                return urls.isEmpty ? nil : urls.removeFirst()
            }
        }

        /// A window of an app with its own defaults, whose studio checks a model file with `helper`,
        /// and its announcements. The window holds its app weakly, so this holds it.
        struct FileWindow {
            let app: AppDelegate
            let model: SessionWindow
            let studio: Studio
            let defaults: UserDefaults
            let file: URL
            let folder: URL
            let heard: Heard

            /// The language choice that a new sheet opens on: the last one, else the app language.
            var choice: WhisperLanguage {
                TranscribeLanguages.first(
                    stored: defaults.string(forKey: TranscribeDraft.languageKey),
                    appLanguage: Bundle.main.preferredLocalizations.first)
            }

            /// The kept file of `choice`.
            func kept(for choice: WhisperLanguage? = nil) -> KeptModelFile? {
                KeptModelFile.load(for: choice ?? self.choice, from: defaults)
            }
        }

        @MainActor final class Heard { var texts: [String] = [] }

        /// A shell script in `folder` with `body`; `$3` is the model file.
        static func stub(_ body: String, in folder: URL) throws -> URL {
            let url = folder.appending(path: "helper-\(UUID().uuidString)")
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        /// A helper that adds a line to `ran`, waits for `gate` when it is given, and passes.
        static func passing(_ folder: URL, ran: URL, gate: URL? = nil) throws -> URL {
            let wait = gate.map { "while [ ! -f '\($0.path)' ]; do sleep 0.05; done; " } ?? ""
            return try stub(
                "echo run >> '\(ran.path)'; \(wait)echo \"sha256=$(shasum -a 256 \"$3\" | cut -d' ' -f1) "
                    + "audio_layers=4 text_layers=4 n_mels=80 multilingual=yes\"",
                in: folder)
        }

        static func refusing(_ folder: URL, ran: URL) throws -> URL {
            try stub("echo run >> '\(ran.path)'; echo 'Error: The file is no whisper model.' >&2; exit 1", in: folder)
        }

        static func runs(_ ran: URL) -> Int {
            (try? String(contentsOf: ran, encoding: .utf8))?.split(separator: "\n").count ?? 0
        }

        func openFile(
            _ helper: @escaping (URL) throws -> URL, picks: Picks, engine: @escaping TranscribeEngine = engine(),
            hashes: OSAllocatedUnfairLock<Int> = OSAllocatedUnfairLock(initialState: 0), device: String = "mic"
        ) async throws -> FileWindow {
            let root = folder.url.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let suite = "TranscribeWindowTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set("es", forKey: TranscribeDraft.languageKey)
            let app = AppDelegate(recordings: nil, defaults: defaults)
            let package = try await timelinePackage(in: root, tracks: 2, seconds: 3, audio: true, device: device)
            let (model, studio, _, _) = try await openLanes(app, package)
            let models = root.appending(path: "Models")
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: models.appending(path: WhisperModel.base.fileName).path, contents: Data([1]))
            model.transcribe.modelFolder = { models }
            studio.environment.transcribe = engine
            studio.environment.transcribeReason = UUID().uuidString
            studio.environment.modelStore = WhisperModelStore(
                folder: models, load: { _ in AsyncThrowingStream { _ in } })
            studio.environment.checkModel = { CheckedModel.unchecked($0, at: $1.appending(path: $0.fileName)) }
            let checker = try helper(root)
            studio.environment.checkModelFile = { url, passed, stop throws(ModelFileCheckError) in
                try ModelFileCheck.run(url, helper: checker, passed: passed, stop: stop)
            }
            model.transcribe.pickModelFile = { _ in picks.next() }
            let hash = studio.environment.hashModelFile
            studio.environment.hashModelFile = { url, stop throws(ModelFileCheckError) in
                hashes.withLock { $0 += 1 }
                return try hash(url, stop)
            }
            let heard = Heard()
            model.chrome?.announce = { text, _ in heard.texts.append(text) }
            let file = root.appending(path: "user.bin")
            try Data("abc".utf8).write(to: file)
            return FileWindow(
                app: app, model: model, studio: studio, defaults: defaults, file: file, folder: root, heard: heard)
        }

        /// The sheet, opened.
        func sheet(_ window: FileWindow) throws -> TranscribeDraft {
            window.model.run(.transcribe)
            return try #require(window.model.transcribe.draft)
        }

        func isRunning(_ model: SessionWindow) -> Bool { model.transcribe.draft?.isChecking == true }

        /// C17 (a): Choose Model File... and a file that passes. While the check runs, the check
        /// line is the only line and Transcribe is off; then the line gives the facts, the
        /// selection is the file, VoiceOver gets the line, and the defaults keep the file.
        @Test func chooseModelFileWithAFileThatPassesSelectsTheFile() async throws {
            let gate = folder.url.appending(path: "gate-\(UUID().uuidString)")
            let ran = folder.url.appending(path: "ran-\(UUID().uuidString)")
            let picks = Picks([])
            let window = try await openFile({ try Self.passing($0, ran: ran, gate: gate) }, picks: picks)
            picks.urls = [window.file]
            let model = window.model
            _ = try sheet(window)

            model.selectModel(.choose)
            await until("the check runs") { isRunning(model) }
            let running = try #require(model.transcribe.draft)
            #expect(running.check == .running(name: "user.bin", byteCount: 3))
            #expect(!running.canStart && running.model == .choose)
            try Data().write(to: gate)
            await until("the check ends") { !isRunning(model) }

            let passed = try #require(model.transcribe.draft)
            #expect(passed.check == .passed(Self.tiny) && passed.model == .file && passed.canStart)
            #expect(window.heard.texts == [ModelCheckLine.text(of: Self.tiny)])
            let kept = try #require(window.kept())
            #expect(kept.path == window.file.path && kept.passed == PassedModelFile(sha256: Self.abc, facts: Self.tiny))
            #expect(Self.runs(ran) == 1)
            await model.close()
        }

        /// C17 (b): a file that fails: the refusal line, VoiceOver, the entry before, and no file kept.
        @Test func aRefusedFileStoresNothing() async throws {
            let ran = folder.url.appending(path: "ran-\(UUID().uuidString)")
            let picks = Picks([])
            let window = try await openFile({ try Self.refusing($0, ran: ran) }, picks: picks)
            picks.urls = [window.file]
            let before = try sheet(window).model

            window.model.selectModel(.choose)
            await until("the refusal shows") {
                if case .refused? = window.model.transcribe.draft?.check { true } else { false }
            }

            let draft = try #require(window.model.transcribe.draft)
            let text = L10n.message(for: ModelFileCheckError.refused(.unknown("The file is no whisper model.")))
            #expect(draft.check == .refused(text) && draft.model == before)
            #expect(window.heard.texts == [text])
            #expect(window.kept() == nil && Self.runs(ran) == 1)
            await window.model.close()
        }

        /// C17 (c): Cancel in the panel gives back the entry before, with no check.
        @Test func aCancelInThePanelRunsNoCheck() async throws {
            let ran = folder.url.appending(path: "ran-\(UUID().uuidString)")
            let picks = Picks([nil])
            let window = try await openFile({ try Self.passing($0, ran: ran) }, picks: picks)
            let before = try sheet(window).model

            window.model.selectModel(.choose)
            await until("the panel closes") { picks.count == 1 && window.model.transcribe.draft?.model == before }

            #expect(window.model.transcribe.draft?.check == nil && Self.runs(ran) == 0)
            await window.model.close()
        }

        /// C17 (d), C18: a kept file shows in the next sheet with the facts of its record and no
        /// helper; a new pick replaces it.
        @Test func aPassedFileIsKeptForTheNextSheetAndANewPickReplacesIt() async throws {
            let ran = folder.url.appending(path: "ran-\(UUID().uuidString)")
            let picks = Picks([])
            let window = try await openFile({ try Self.passing($0, ran: ran) }, picks: picks)
            let other = window.folder.appending(path: "other.bin")
            try Data("abcd".utf8).write(to: other)
            picks.urls = [window.file, other]
            _ = try sheet(window)
            window.model.selectModel(.choose)
            await until("the first check passes") { window.model.transcribe.draft?.model == .file }
            window.model.cancelTranscribeSheet()

            let next = try sheet(window)
            #expect(next.kept?.path == window.file.path && next.entries.contains(.file))
            window.model.selectModel(.file)
            #expect(window.model.transcribe.draft?.modelNotes.first == ModelCheckLine.text(of: Self.tiny))
            #expect(Self.runs(ran) == 1, "the sheet shows the record with no check")
            window.model.selectModel(.choose)
            await until("the second check passes") { window.model.transcribe.draft?.kept?.path == other.path }
            #expect(window.kept()?.path == other.path && Self.runs(ran) == 2)
            await window.model.close()
        }

        /// C18: a kept file that is gone shows as missing; its choice opens the panel, and a Cancel
        /// gives back the entry before.
        @Test func aMissingKeptFileShowsMissingAndItsChoiceOpensThePanel() async throws {
            let picks = Picks([nil])
            let window = try await openFile({ try Self.passing($0, ran: $0.appending(path: "ran")) }, picks: picks)
            let gone = window.folder.appending(path: "gone.bin")
            KeptModelFile(
                url: gone, status: FileStatus(byteCount: 3, modified: .now),
                passed: PassedModelFile(sha256: Self.abc, facts: Self.tiny)
            ).store(for: window.choice, in: window.defaults)
            let before = try sheet(window).model
            await until("the status read ends") { window.model.transcribe.draft?.keptMissing == true }

            window.model.selectModel(.file)
            await until("the panel closes") { picks.count == 1 && window.model.transcribe.draft?.model == before }
            await window.model.close()
        }

        enum Status: CaseIterable { case same, newDate, newSize, missing, newDateDuringATake }

        /// C24: the sheet open reads the status of the kept file; only a new byte count or date
        /// hashes it, and not while another studio starts a take. (a) and (b) are the near pair.
        @Test(arguments: Status.allCases) func theSheetOpenHashesOnlyAChangedFile(status: Status) async throws {
            let hashes = OSAllocatedUnfairLock(initialState: 0)
            let window = try await openFile(
                { try Self.passing($0, ran: $0.appending(path: "ran")) }, picks: Picks([]), hashes: hashes)
            let kept = KeptModelFile(
                url: window.file, status: try #require(FileStatus(of: window.file)),
                passed: PassedModelFile(sha256: Self.abc, facts: Self.tiny))
            kept.store(for: window.choice, in: window.defaults)
            let newDate = Date(timeIntervalSinceNow: -3_600)
            var other: FileWindow?
            defer { other?.studio.isStarting = false }
            switch status {
            case .same: break
            case .newDate:
                try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: window.file.path)
            case .newSize: try Data("abcd".utf8).write(to: window.file)
            case .missing: try FileManager.default.removeItem(at: window.file)
            case .newDateDuringATake:
                try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: window.file.path)
                let second = try await openFile({ $0 }, picks: Picks([]))
                second.studio.isStarting = true
                window.studio.otherStudios = { [second.studio] }
                other = second
            }

            _ = try sheet(window)
            await window.model.transcribe.keptTask?.value

            let stored = try #require(window.kept())
            let expected =
                switch status {
                case .same, .missing, .newDateDuringATake: 0
                case .newDate, .newSize: 1
                }
            #expect(hashes.withLock { $0 } == expected)
            #expect(window.model.transcribe.draft?.keptMissing == (status == .missing))
            switch status {
            case .same, .missing, .newDateDuringATake: #expect(stored == kept)
            case .newDate: #expect(stored.passed == kept.passed && stored.modified != kept.modified)
            case .newSize: #expect(stored.passed == nil && stored.byteCount == 4)
            }
            if let other {
                window.studio.otherStudios = { [] }
                other.studio.isStarting = false
                await boundedClose(other.model)
            }
            await boundedClose(window.model)
        }

        /// A sheet hash of the kept file that ends after the pick of another file stores nothing:
        /// the defaults keep the pick. The hash waits for a gate that opens after the pick passes.
        @Test func aSheetHashThatEndsAfterANewPickKeepsThePick() async throws {
            let picks = Picks([])
            let window = try await openFile({ try Self.passing($0, ran: $0.appending(path: "ran")) }, picks: picks)
            KeptModelFile(
                url: window.file, status: FileStatus(byteCount: 3, modified: Date(timeIntervalSinceNow: -3_600)),
                passed: PassedModelFile(sha256: Self.abc, facts: Self.tiny)
            ).store(for: window.choice, in: window.defaults)
            let other = window.folder.appending(path: "other.bin")
            try Data("abc".utf8).write(to: other)
            picks.urls = [other]
            let (started, gate) = (
                OSAllocatedUnfairLock(initialState: false), OSAllocatedUnfairLock(initialState: false)
            )
            let hash = window.studio.environment.hashModelFile
            window.studio.environment.hashModelFile = { url, stop throws(ModelFileCheckError) in
                started.withLock { $0 = true }
                while !gate.withLock({ $0 }) && !stop() { usleep(1_000) }
                return try hash(url, stop)
            }

            _ = try sheet(window)
            await until("the sheet hash of the kept file runs") { started.withLock { $0 } }
            window.model.selectModel(.choose)
            await until(limit: .seconds(5), "the pick passes") {
                window.model.transcribe.draft?.kept?.path == other.path
            }
            gate.withLock { $0 = true }
            await window.model.transcribe.keptTask?.value

            #expect(window.kept()?.path == other.path)
            await window.model.close()
        }

        enum CheckStop: CaseIterable { case popUp, cancel, settle, take }

        /// C25: a pop-up change, Cancel, the close of the window, and a take start (`endReads(.take)`,
        /// as each take start calls it on each studio) stop the helper; nothing is kept.
        @Test(arguments: CheckStop.allCases) func eachStopEndsTheSheetCheck(stop: CheckStop) async throws {
            let pidFile = folder.url.appending(path: "pid-\(UUID().uuidString)")
            let picks = Picks([])
            let window = try await openFile(
                {
                    try Self.stub(
                        "echo $$ > '\(pidFile.path)'.tmp; mv '\(pidFile.path)'.tmp '\(pidFile.path)'; exec sleep 30",
                        in: $0)
                }, picks: picks)
            picks.urls = [window.file]
            let model = window.model
            let before = try sheet(window).model
            model.selectModel(.choose)
            await until(limit: .seconds(10), "the helper wrote its PID") {
                FileManager.default.fileExists(atPath: pidFile.path)
            }
            let pid = try #require(pid_t(String(decoding: Data(contentsOf: pidFile), as: UTF8.self).filter(\.isNumber)))

            switch stop {
            case .popUp: model.selectModel(.catalog(.base))
            case .cancel: model.cancelTranscribeSheet()
            case .settle: await model.close()
            case .take: window.studio.endReads(.take)
            }
            await until(limit: .seconds(5), "the helper \(pid) ends") { kill(pid, 0) == -1 && errno == ESRCH }

            let draft = model.transcribe.draft
            switch stop {
            case .popUp: #expect(draft?.model == .catalog(.base) && draft?.check == nil)
            case .cancel, .settle: #expect(draft == nil)
            case .take:
                await until("the check line names the take") { !isRunning(model) }
                #expect(
                    model.transcribe.draft?.model == before
                        && model.transcribe.draft?.check == .refused(L10n.sheetTranscribeCheckTake.text))
            }
            #expect(window.kept() == nil)
            if stop != .settle { await model.close() }
        }

        /// C25 (f): a pick while another studio starts a take runs no hash and no helper.
        @Test func aCheckDuringATakeInAnotherStudioRunsNothing() async throws {
            let ran = folder.url.appending(path: "ran-\(UUID().uuidString)")
            let picks = Picks([])
            let window = try await openFile({ try Self.passing($0, ran: ran) }, picks: picks)
            picks.urls = [window.file]
            let seams = OSAllocatedUnfairLock(initialState: 0)
            let check = window.studio.environment.checkModelFile
            window.studio.environment.checkModelFile = { url, passed, stop throws(ModelFileCheckError) in
                seams.withLock { $0 += 1 }
                return try check(url, passed, stop)
            }
            let second = try await openFile({ $0 }, picks: Picks([]))
            second.studio.isStarting = true
            defer { second.studio.isStarting = false }
            window.studio.otherStudios = { [second.studio] }
            let before = try sheet(window).model

            window.model.selectModel(.choose)
            await until("the refusal shows") { window.model.transcribe.draft?.check != nil && !isRunning(window.model) }

            #expect(window.model.transcribe.draft?.check == .refused(L10n.sheetTranscribeCheckBusy.text))
            #expect(window.model.transcribe.draft?.model == before)
            #expect(seams.withLock { $0 } == 0 && Self.runs(ran) == 0)
            #expect(window.kept() == nil)
            window.studio.otherStudios = { [] }
            second.studio.isStarting = false
            await boundedClose(second.model)
            await boundedClose(window.model)
        }
    }
#endif
