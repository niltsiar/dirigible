import DirigibleCore
import Foundation
import Testing

/// C5 and C6: `dirigible model check <path>`, the helper of a model file check (decision 0065, D8).
struct ModelCommandTests {
    @Test func aFileThatTheParseRefusesExits1WithTheReason() async throws {
        let temporary = try TemporaryPackage(Session(sampleRate: 48_000))
        let file = temporary.folder.appending(path: "magic-only.bin")
        try Data([0x6c, 0x6d, 0x67, 0x67]).write(to: file)

        let result = try await dirigible("model", "check", file.path)

        #expect(
            result == CLIResult(status: 1, stdout: "", stderr: "Error: The model file ends before its last part.\n"))
    }

    @Test func theSileroFileExits1() async throws {
        let silero = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Support/Resources/ggml-silero-v6.2.0.bin")

        let result = try await dirigible("model", "check", silero.path)

        #expect(
            result
                == CLIResult(
                    status: 1, stdout: "",
                    stderr: "Error: The model file has a value that Dirigible cannot run: n_vocab 10.\n"))
    }

    /// The path `-` is the protocol of the app: the reason is a code, which the app writes in its own language.
    @Test func theProtocolFormGivesTheReasonAsACode() async throws {
        let temporary = try TemporaryPackage(Session(sampleRate: 48_000))
        let file = temporary.folder.appending(path: "magic-only.bin")
        try Data([0x6c, 0x6d, 0x67, 0x67]).write(to: file)

        let result = try await dirigible(["model", "check", "-"], input: file)

        #expect(result == CLIResult(status: 1, stdout: "", stderr: "Refusal: truncated\n"))
    }

    @Test func aMissingFileExits1() async throws {
        let temporary = try TemporaryPackage(Session(sampleRate: 48_000))
        let missing = temporary.folder.appending(path: "missing.bin")

        let result = try await dirigible("model", "check", missing.path)

        #expect(
            result
                == CLIResult(
                    status: 1, stdout: "", stderr: "Error: The model file cannot be read: No such file or directory.\n")
        )
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func noPathExits64() async throws {
        let result = try await dirigible("model", "check")

        #expect(result.status == 64 && result.stdout.isEmpty, "\(result)")
        #expect(result.stderr.contains("Missing expected argument '<path>'"), "\(result.stderr)")
    }

    /// The tiny-q5_1 fixture passes the parse and the trial.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theTinyFixturePasses() async throws {
        let tiny = try #require(Self.tinyFixture, "no ggml-tiny-q5_1.bin: run scripts/fetch-whisper-test-model.sh")

        let result = try await dirigible("model", "check", tiny.path)

        #expect(
            result
                == CLIResult(
                    status: 0,
                    stdout: "sha256=818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7 audio_layers=4 "
                        + "text_layers=4 n_mels=80 multilingual=yes\n",
                    stderr: ""))
    }

    /// The handlers turn the abort of the debug abort point into exit 134 (128 + SIGABRT).
    @Test func anAbortInTheCommandIsExitStatus134() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "dirigible-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = childProcess(
            dirigibleBinary, ["model", "check", folder.appending(path: "any.bin").path], in: folder)
        process.environment?["DIRIGIBLE_MODEL_CHECK_ABORT"] = "1"
        process.standardError = FileHandle.nullDevice

        let (reason, status) = try await ended(process)

        #expect(reason == .exit && status == 134, "reason \(reason.rawValue), status \(status)")
    }

    private static var tinyFixture: URL? {
        let environment = ProcessInfo.processInfo.environment
        let cache =
            environment["XDG_CACHE_HOME"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache")
        let file = cache.appending(path: "dirigible/whisper/ggml-tiny-q5_1.bin")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// The termination reason and status of `process`, which the `dirigible(...)` helpers do not
    /// give. A run over 30 s is stopped and records an issue.
    private func ended(_ process: Process) async throws -> (Process.TerminationReason, Int32) {
        let watch = Task { [process = UncheckedProcess(value: process)] in
            try await Task.sleep(for: .seconds(30))
            process.value.terminate()
            Issue.record("dirigible model check ran for more than 30 s")
        }
        defer { watch.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = {
                continuation.resume(returning: ($0.terminationReason, $0.terminationStatus))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

/// A `Process` for the limit task, which only stops it.
private struct UncheckedProcess: @unchecked Sendable {
    let value: Process
}
