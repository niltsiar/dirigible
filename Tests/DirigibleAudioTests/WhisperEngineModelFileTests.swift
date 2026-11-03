import Foundation
import Testing

@testable import DirigibleAudio

/// The engine load of a model file of the user reads the file that its check opened, and compares
/// the SHA-256 of the bytes that it loaded with the record of the check (decision 0065, D8). The
/// file is a copy of the tiny-q5_1 fixture, checked with its known SHA-256, so no helper runs. Each
/// test is slow-gated.
struct WhisperEngineModelFileTests {
    let folder: TemporaryFolder
    let file: URL
    let checked: CheckedModel

    init() throws {
        folder = try TemporaryFolder()
        file = folder.url.appending(path: "user.bin")
        try FileManager.default.copyItem(at: WhisperFixture.model(.tinyQ51).url, to: file)
        let record = PassedModelFile(sha256: WhisperModel.tinyQ51.sha256, facts: ModelFileCheckTests.facts)
        checked = try ModelFileCheck.run(file, helper: folder.url.appending(path: "no-helper"), passed: record) {
            false
        }
    }

    #if DEBUG
        /// The job reads the file in the app twice (decision 0065 D8): the hash of the check and the load.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
        func theJobReadsTheFileTwiceInTheApp() throws {
            let size = WhisperModel.tinyQ51.byteCount
            #expect(checked.file?.bytesRead == size, "the hash of the check")

            _ = try WhisperEngine(model: checked, vad: nil, log: .disabled)

            #expect(checked.file?.bytesRead == 2 * size, "the hash and the load")
        }
    #endif

    /// A rename of another file over the path after the check: the engine loads the checked bytes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aRenameOverThePathAfterTheCheckLoadsTheCheckedBytes() throws {
        let other = folder.url.appending(path: "other.bin")
        try Data("not a model".utf8).write(to: other)
        #expect(rename(other.path, file.path) == 0)

        _ = try WhisperEngine(model: checked, vad: nil, log: .disabled)
    }

    /// A write into the file after the check: the bytes that the engine loads have another SHA-256,
    /// and the load throws `.modelChanged`. The write is in the data of the last tensor.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aWriteIntoTheFileAfterTheCheckThrowsModelChanged() throws {
        let handle = try FileHandle(forWritingTo: file)
        try handle.seek(toOffset: UInt64(WhisperModel.tinyQ51.byteCount - 64))
        try handle.write(contentsOf: Data(repeating: 0x55, count: 64))
        try handle.close()

        #expect(throws: TranscribeError.modelChanged) {
            _ = try WhisperEngine(model: checked, vad: nil, log: .disabled)
        }
    }

    /// A stop that is set before the load ends the load after the hparams (byte 48) with no process
    /// death: the load throws `.modelLoad`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aStopSetBeforeTheLoadEndsItWithNoAbort() throws {
        let stop = StopFlag()
        stop.set()

        #expect(throws: TranscribeError.modelLoad) {
            _ = try WhisperEngine(model: checked, vad: nil, log: .disabled, stop: stop)
        }
    }
}
