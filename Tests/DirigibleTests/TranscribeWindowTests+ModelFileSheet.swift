import AppKit
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

#if DEBUG
    /// The sheet of a model file of the user (decision 0065 D8, code gate 1 items 7, 8, 12, and 14):
    /// the kept file of each language choice, the language lock after a dropped record, the height
    /// of the sheet, the text of a file that changed in the check, and the window of the open panel.
    extension TranscribeWindowTests {
        static let englishOnly = WhisperModelFacts(audioLayers: 4, textLayers: 4, melCount: 80, isMultilingual: false)

        /// A helper that passes the file "abc" as multilingual and any other file as English only.
        static func byContent(_ folder: URL) throws -> URL {
            try stub(
                "h=$(shasum -a 256 \"$3\" | cut -d' ' -f1); m=no; [ \"$h\" = \(abc) ] && m=yes; "
                    + "echo \"sha256=$h audio_layers=4 text_layers=4 n_mels=80 multilingual=$m\"",
                in: folder)
        }

        /// The sheet on `language`: Choose Model File... with `file`, and Transcribe after the pass.
        func pickAndStart(_ window: FileWindow, _ picks: Picks, file: URL, language: WhisperLanguage) async throws {
            window.defaults.set(TranscribeLanguages.stored(language), forKey: TranscribeDraft.languageKey)
            picks.urls = [file]
            _ = try sheet(window)
            window.model.selectModel(.choose)
            await until("the check passes") { window.model.transcribe.draft?.model == .file }
            window.model.startTranscribe(try #require(window.model.transcribe.draft))
            await window.model.transcribe.task?.value
            await until("the file is kept") { window.kept(for: language)?.path == file.path }
        }

        /// Item 7: a language choice opens on the file that it last passed with. Spanish passes with
        /// the multilingual file A, English with the English-only file B; a new Spanish sheet shows A
        /// with the language pop-up on.
        @Test func aLanguageChoiceOpensOnTheFileThatItLastPassedWith() async throws {
            let picks = Picks([])
            let window = try await openFile({ try Self.byContent($0) }, picks: picks)
            let english = window.folder.appending(path: "english.bin")
            try Data("only english".utf8).write(to: english)
            try await pickAndStart(window, picks, file: window.file, language: .code("es"))
            try await pickAndStart(window, picks, file: english, language: .code("en"))

            window.defaults.set("es", forKey: TranscribeDraft.languageKey)
            let spanish = try sheet(window)

            #expect(spanish.kept?.path == window.file.path && spanish.model == .file)
            #expect(spanish.language == .code("es") && !spanish.languageLocked)
            await window.model.close()
        }

        /// Item 7: a kept English-only file locks the language; when the sheet open finds the file
        /// changed and drops its record, the lock goes and the language comes back.
        @Test func aDroppedRecordReleasesTheLanguageLock() async throws {
            let window = try await openFile({ try Self.passing($0, ran: $0.appending(path: "ran")) }, picks: Picks([]))
            KeptModelFile(
                url: window.file, status: FileStatus(byteCount: 9, modified: Date(timeIntervalSinceNow: -3_600)),
                passed: PassedModelFile(sha256: String(repeating: "b", count: 64), facts: Self.englishOnly)
            ).store(for: .code("es"), in: window.defaults)
            TranscribeModelMemory.remember(.file, for: .code("es"), in: window.defaults)

            let opened = try sheet(window)
            #expect(opened.model == .file && opened.languageLocked && opened.language == .code("en"))
            await window.model.transcribe.keptTask?.value

            let after = try #require(window.model.transcribe.draft)
            #expect(after.kept?.passed == nil && after.model == .file)
            #expect(after.language == .code("es") && !after.languageLocked)
            await window.model.close()
        }

        /// Item 12: a file that changes during the check of the sheet gives a text about the check,
        /// not about a transcription.
        @Test func aFileThatChangesDuringTheSheetCheckNamesTheCheck() async throws {
            let picks = Picks([])
            let window = try await openFile(
                {
                    try Self.stub(
                        "echo 'sha256=\(String(repeating: "c", count: 64)) audio_layers=4 text_layers=4 "
                            + "n_mels=80 multilingual=yes'", in: $0)
                }, picks: picks)
            picks.urls = [window.file]
            _ = try sheet(window)

            window.model.selectModel(.choose)
            await until("the refusal shows") { window.model.transcribe.draft?.check != nil && !isRunning(window.model) }

            #expect(window.model.transcribe.draft?.check == .refused(L10n.sheetTranscribeCheckChanged.text))
            #expect(L10n.sheetTranscribeCheckChanged.text != L10n.errorTranscribeFileChanged.text)
            await window.model.close()
        }

        /// The open panel of Choose Model File... and of Locate... gets the window of the sheet.
        @Test func theOpenPanelGetsTheWindowOfTheSheet() async throws {
            let picks = Picks([])
            let window = try await openFile({ try Self.passing($0, ran: $0.appending(path: "ran")) }, picks: picks)
            picks.urls = [window.file, nil]
            let parents = Parents()
            window.model.transcribe.pickModelFile = { parent in
                parents.windows.append(parent)
                return picks.next()
            }
            _ = try sheet(window)
            window.model.selectModel(.choose)
            await until("the check passes") { window.model.transcribe.draft?.model == .file }
            let request = try #require(window.model.transcribe.draft?.request)
            window.model.startWithPickedFile(request)
            await until("the second panel closes") { parents.windows.count == 2 }

            let hosts = [window.model.window, window.model.window?.attachedSheet].compactMap { $0 }
            #expect(
                parents.windows.count == 2 && parents.windows.allSatisfy { parent in hosts.contains { $0 === parent } })
            await window.model.close()
        }

        @MainActor final class Panel {
            var opened = 0
            var gone = 0
            /// An open panel that stays until its calling task is cancelled.
            func pick(_: NSWindow?) async -> URL? {
                opened += 1
                try? await Task.sleep(for: .seconds(30))
                gone += 1
                return nil
            }
        }

        enum PanelStart: CaseIterable { case chooseModelFile, locate }
        enum PanelEnd: CaseIterable { case cancelSheet, closeWindow }

        /// Code gate 2 item 3: each open panel of the model file flow (Choose Model File..., and
        /// Locate... or Choose Model File... of a job alert) closes when the sheet or the window closes.
        @Test(arguments: PanelStart.allCases, PanelEnd.allCases)
        func eachOpenPanelClosesWithItsSheetOrWindow(start: PanelStart, end: PanelEnd) async throws {
            let window = try await openFile({ $0 }, picks: Picks([]))
            let panel = Panel()
            window.model.transcribe.pickModelFile = { await panel.pick($0) }
            let draft = try sheet(window)
            switch start {
            case .chooseModelFile: window.model.selectModel(.choose)
            case .locate: window.model.startWithPickedFile(try #require(draft.request))
            }
            await until("the panel opens") { panel.opened == 1 }

            switch end {
            case .cancelSheet: window.model.cancelTranscribeSheet()
            case .closeWindow: await window.model.close()
            }

            await until(limit: .seconds(5), "the panel closes") { panel.gone == 1 }
            if end == .cancelSheet { await window.model.close() }
        }

        @MainActor final class Parents { var windows: [NSWindow?] = [] }

        /// The height of the sheet for the sheet check line: `nil` is the sheet with no line.
        func sheetHeight(_ window: FileWindow, _ draft: TranscribeDraft, line: ModelCheckLine?) -> CGFloat {
            var draft = draft
            draft.check = line
            window.model.transcribe.draft = draft
            let host = NSHostingView(rootView: TranscribeSheet(model: window.model))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }

        /// Item 8: the sheet has one height for each state of the check line, with and without a
        /// replace note, and with the kept file selected (C17, U17, M2).
        @Test(arguments: [0, 2]) func theSheetKeepsOneHeightForEachStateOfTheCheckLine(words: Int) async throws {
            let window = try await openFile({ $0 }, picks: Picks([]))
            let refusal = String(repeating: "The model file is damaged and cannot be used here. ", count: 3)
            let longRefusal = String(repeating: "A helper reason that runs on and on. ", count: 20)
            let longName = String(repeating: "a-long-file-name-", count: 12) + ".bin"
            let lines: [ModelCheckLine?] = [
                nil, .running(name: "ggml-medium.bin", byteCount: 600_000_000), .passed(Self.tiny),
                .refused("The file is not a ggml whisper model."), .refused(refusal), .refused(longRefusal),
                .running(name: longName, byteCount: 600_000_000),
            ]
            let kept = KeptModelFile(
                url: window.file, status: FileStatus(byteCount: 3, modified: .now),
                passed: PassedModelFile(sha256: Self.abc, facts: Self.tiny))
            for entry in [ModelEntry.catalog(.base), .file] {
                var draft = try TranscribeSheetTests.sheet(.code("en"), kept: kept, words: words)
                draft.select(entry)
                let heights = lines.map { sheetHeight(window, draft, line: $0) }
                #expect(heights.allSatisfy { $0 > 100 }, "the sheet is laid out: \(heights)")
                #expect(Set(heights).count == 1, "\(entry) with \(words) words: \(heights)")
            }
            await window.model.close()
        }
    }
#endif
