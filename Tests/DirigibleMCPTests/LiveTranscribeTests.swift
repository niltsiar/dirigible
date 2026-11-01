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

        /// Gate 1 item 4. MCP progress must grow, so the tool has one scale for both stages: the
        /// download from 0 to 0.2, the transcription from 0.2 to 1.
        @Test func theToolScaleGrowsFromTheDownloadIntoTheTranscription() {
            #expect(toolFraction(.download(0)) == 0 && toolFraction(.download(1)) == 0.2)
            #expect(toolFraction(.transcribe(0)) == 0.2 && toolFraction(.transcribe(1)) == 1)
            #expect(toolFraction(.download(0.99)) < toolFraction(.transcribe(0.01)))
        }

        /// The check of a model file takes the place of the download: it starts at 0, and its end
        /// gives no new fraction, so the gate sends nothing for it.
        @Test func theCheckOfAModelFileIsAtTheStartOfTheScale() {
            let record = PassedModelFile(
                sha256: String(repeating: "0", count: 64),
                facts: WhisperModelFacts(audioLayers: 4, textLayers: 4, melCount: 80, isMultilingual: true))
            #expect(toolFraction(.check) == 0 && toolFraction(.checked(record)) == 0)
            #expect(toolFraction(.checked(record)) < toolFraction(.transcribe(0.01)))
        }

        /// C15 in the app: the job checks the file once, the engine gets that file, and the text ends
        /// with the SHA-256 of the file.
        @Test func theToolTranscribesWithAModelFile() async throws {
            let language = OSAllocatedUnfairLock<WhisperLanguage?>(initialState: nil)
            let words = [TimedWord(text: "hola", start: 50, end: 100)]
            let studio = try await open(words, language: language)
            let file = package.folder.appending(path: "user.bin")
            try Data("abc".utf8).write(to: file)
            let hash = try sha256(of: file)
            let record = PassedModelFile(
                sha256: hash,
                facts: WhisperModelFacts(audioLayers: 4, textLayers: 4, melCount: 80, isMultilingual: true))
            let (checks, models) = (
                OSAllocatedUnfairLock(initialState: [URL]()), OSAllocatedUnfairLock(initialState: [CheckedModel]())
            )
            studio.environment.checkModelFile = { url, _, _ throws(ModelFileCheckError) in
                checks.withLock { $0.append(url) }
                return CheckedModel(record, opened: try OpenModelFile(url), at: url)
            }
            studio.environment.transcribe = { model, _, count, _, _, _, _ throws(TranscribeError) in
                models.withLock { $0.append(model) }
                return Transcription(pieces: [words] + Array(repeating: [], count: max(0, count - 1)), language: "es")
            }
            let (server, folder) = try liveServer(studio)
            defer { server.stop() }

            let outcome = await send(
                folder.socket, "transcribe",
                ["package": package.path, "track": "t1", "language": "es", "model_file": file.path])

            let text = "1\nImported 1 word.\nModel file SHA-256: \(hash)"
            #expect(outcome == .reply(.result(text: text, isError: false)), "\(outcome)")
            #expect(checks.withLock { $0 } == [file])
            #expect(models.withLock { $0.map(\.source) } == [.file(record)])
            #expect(studio.session.words().map(\.text) == ["hola"])
            await studio.settle()
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
