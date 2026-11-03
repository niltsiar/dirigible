import AppKit
import DirigibleTimeline
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

#if DEBUG
    /// A failed model download in the session window (decision 0065, D2): each fault shows its alert
    /// in the window, and the Transcribe sheet starts a second download at byte 0.
    extension TranscribeWindowTests {
        enum DownloadFault: CaseIterable {
            case connectionLost, badResponse, folderTakesNoFile

            func error(models: URL) -> TranscribeError {
                switch self {
                case .connectionLost, .badResponse: .modelDownload
                case .folderTakesNoFile: .modelWrite(folder: models.path, errno: EACCES)
                }
            }
        }

        /// The models folder, the first download, and the number of loader calls. The first call
        /// gives one chunk and then fails as `fault`; each other call gives 1 MB and holds. A folder
        /// that takes no file fails before the first call.
        struct FailingDownload {
            let models: URL
            let loads = OSAllocatedUnfairLock(initialState: 0)

            func restoreFolder() {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: models.path)
            }

            /// The size of the `.download` file in the models folder, else nil.
            var downloadSize: Int? {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: models.path)) ?? []
                return names.first { $0.hasSuffix(".download") }.flatMap {
                    try? models.appending(path: $0).resourceValues(forKeys: [.fileSizeKey]).fileSize
                }
            }

            var files: [String] { (try? FileManager.default.contentsOfDirectory(atPath: models.path)) ?? ["?"] }
        }

        func openFailing(_ fault: DownloadFault) async throws -> (SessionWindow, Studio, FailingDownload) {
            let (model, studio) = try await open(withModel: false)
            let models = studio.environment.modelStore.folder
            let download = FailingDownload(models: models)
            let small = Self.small
            studio.environment.modelStore = WhisperModelStore(folder: models) { _ in
                let call = download.loads.withLock {
                    $0 += 1
                    return $0
                }
                return AsyncThrowingStream { continuation in
                    guard call == 1, fault != .folderTakesNoFile else {
                        continuation.yield(Data(count: 1 << 20))
                        return
                    }
                    continuation.yield(small)
                    switch fault {
                    case .connectionLost: continuation.finish(throwing: URLError(.networkConnectionLost))
                    case .badResponse: continuation.finish(throwing: URLError(.badServerResponse))
                    case .folderTakesNoFile: break
                    }
                }
            }
            if fault == .folderTakesNoFile {
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: models.path)
            }
            return (model, studio, download)
        }

        /// Presses OK of the alert in the session window, and returns the text of the alert.
        func pressOK(_ model: SessionWindow) async throws -> (buttons: [String], texts: [String]) {
            let window = try #require(model.window)
            await until(limit: .seconds(10), "the alert shows") { window.attachedSheet != nil }
            let sheet = try #require(window.attachedSheet)
            let content = try #require(sheet.contentView)
            let buttons = HeaderStateLineTests.buttons(content)
            let shown = (buttons.map(\.title), HeaderStateLineTests.textFields(content).map(\.stringValue))
            try #require(buttons.first { $0.title == L10n.alertOK.text }, "\(shown.0)").performClick(nil)
            await until(limit: .seconds(10), "the alert goes") { model.alert == nil && window.attachedSheet == nil }
            return shown
        }

        /// C4: each fault gives its alert in the session window with the OK button only, the text of
        /// its error, no banner, no job, no file, and an unchanged session.
        @Test(arguments: DownloadFault.allCases)
        func aDownloadFaultShowsItsAlertInTheSessionWindow(fault: DownloadFault) async throws {
            let (model, studio, download) = try await openFailing(fault)
            defer { download.restoreFolder() }
            let before = studio.session

            try transcribe(model)
            await model.transcribe.task?.value

            let expected = fault.error(models: download.models)
            #expect(model.alert == .error(.transcription(expected)))
            #expect(model.transcribe.job == nil && model.transcribe.task == nil && model.transcribe.download == nil)
            #expect(banners(model).isEmpty && studio.session == before && model.transcribe.notice == nil)
            #expect(download.files == [])
            let text = L10n.message(for: expected)
            #expect(text != L10n.message(for: .modelDownloadNoData(host: "huggingface.co")))
            #expect((text == L10n.message(for: .modelDownload)) == (expected == .modelDownload))
            if case .modelWrite(let folder, let code) = expected {
                // The test runner has no string table, so the English table gives the format.
                let english = try #require(try stringsTable("en")["error.transcribe.folder"])
                let line = String(format: english, folder, Int(code))
                #expect(line.contains(download.models.path) && line.contains("13"), "\(line)")
            }
            let shown = try await pressOK(model)
            #expect(shown.buttons == [L10n.alertOK.text], "OK only")
            #expect(shown.texts.contains { $0.contains(text) }, "\(shown.texts)")
            await model.close()
        }

        /// C5: after OK, Transcribe is on, the sheet offers the download, and the second job starts
        /// at byte 0: its `.download` file holds the first 1 MB of its own load only. Cancel ends it
        /// with no alert and no file.
        @Test(arguments: DownloadFault.allCases)
        func aFailedDownloadLeavesTheTranscribeSheetUsable(fault: DownloadFault) async throws {
            let (model, _, download) = try await openFailing(fault)
            defer { download.restoreFolder() }
            try transcribe(model)
            await model.transcribe.task?.value
            _ = try await pressOK(model)
            download.restoreFolder()

            #expect(model.isOn(.transcribe))
            model.run(.transcribe)
            var draft = try #require(model.transcribe.draft)
            #expect(draft.needsDownload)
            draft.language = .code("es")
            model.startTranscribe(draft)

            #expect(model.transcribe.job?.stage == .download(0))
            await until("the second download holds 1 MB") { download.downloadSize == 1 << 20 }
            #expect(download.loads.withLock { $0 } == (fault == .folderTakesNoFile ? 1 : 2))
            model.cancelTranscribe()
            await until("the job ends") { model.transcribe.job == nil }
            #expect(model.alert == nil && model.transcribe.notice == nil)
            #expect(download.files == [])
            await model.close()
        }
    }
#endif
