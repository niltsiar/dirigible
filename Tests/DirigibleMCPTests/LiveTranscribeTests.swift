import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio
@testable import DirigibleMCP

#if DEBUG
    /// The tool `transcribe` on a package that the app has open (decision 0065): it runs
    /// `Studio.transcribe` as a live job, with a scripted engine part.
    @MainActor
    struct LiveTranscribeTests {
        let package: LivePackage

        init() throws {
            package = try LivePackage()
            try package.addTone()
        }

        /// A studio whose engine part gives `words` as piece 0 and records the language it got.
        func open(_ words: [TimedWord], language: OSAllocatedUnfairLock<WhisperLanguage?>) async throws -> Studio {
            let studio = try await package.open()
            let folder = package.folder.appending(path: "Models")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: folder.appending(path: WhisperModel.base.fileName).path, contents: Data([1]))
            studio.environment.modelStore = WhisperModelStore(folder: folder) { _ in
                AsyncThrowingStream { $0.finish() }
            }
            studio.environment.checkModel = { model, folder in
                CheckedModel.unchecked(model, at: folder.appending(path: model.fileName))
            }
            studio.environment.transcribeReason = UUID().uuidString
            studio.environment.transcribe = { _, asked, count, _, _, _, _ throws(TranscribeError) in
                language.withLock { $0 = asked }
                return Transcription(pieces: [words] + Array(repeating: [], count: max(0, count - 1)), language: "es")
            }
            return studio
        }

        @Test func theToolAddsTheWordsInTheWindow() async throws {
            let language = OSAllocatedUnfairLock<WhisperLanguage?>(initialState: nil)
            let words = [TimedWord(text: "hola", start: 50, end: 100), TimedWord(text: "mundo", start: 150, end: 200)]
            let studio = try await open(words, language: language)
            let (server, folder) = try liveServer(studio)
            defer { server.stop() }

            let outcome = await send(
                folder.socket, "transcribe", ["package": package.path, "track": "t1", "language": "es"])

            #expect(outcome == .reply(.result(text: "1\nImported 2 words.", isError: false)), "\(outcome)")
            #expect(language.withLock { $0 } == .code("es"))
            #expect(studio.session.words().map(\.text) == ["hola", "mundo"])
            await studio.settle()
        }

        /// No kept word: the text is only the `Imported` line, and the session does not change.
        @Test func noWordGivesOnlyTheImportedLine() async throws {
            let studio = try await open([], language: OSAllocatedUnfairLock(initialState: nil))
            let (server, folder) = try liveServer(studio)
            defer { server.stop() }
            let before = studio.session

            let outcome = await send(folder.socket, "transcribe", ["package": package.path, "track": "t1"])

            #expect(outcome == .reply(.result(text: "Imported 0 words.", isError: false)), "\(outcome)")
            #expect(studio.session == before)
            await studio.settle()
        }
    }
#endif
