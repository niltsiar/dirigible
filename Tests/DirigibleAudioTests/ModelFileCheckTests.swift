import Foundation
import Testing

@testable import DirigibleAudio

/// C7, C8, C9, and C25 (f): the app side of a model file check (decision 0065, D8), with stub
/// helpers. The model file is the text "abc", whose SHA-256 the stubs print.
struct ModelFileCheckTests {
    static let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    static let facts = WhisperModelFacts(audioLayers: 4, textLayers: 4, melCount: 80, isMultilingual: true)
    static let passLine = "sha256=\(abc) audio_layers=4 text_layers=4 n_mels=80 multilingual=yes"

    let folder: TemporaryFolder
    let model: URL

    init() throws {
        folder = try TemporaryFolder()
        model = folder.url.appending(path: "model.bin")
        try Data("abc".utf8).write(to: model)
    }

    @Test func aHelperThatAbortsGivesHelperStopped() async throws {
        let helper = try stub("kill -ABRT $$")

        #expect(await check(helper) == .failure(.helperStopped(signal: SIGABRT)))
    }

    @Test func aHelperThatExits134GivesHelperStopped() async throws {
        let helper = try stub("exit 134")

        #expect(await check(helper) == .failure(.helperStopped(signal: SIGABRT)))
    }

    @Test func aHelperThatPrintsTheHashGivesACheckedModel() async throws {
        let helper = try stub("echo '\(Self.passLine)'")

        let result = await check(helper)

        let record = PassedModelFile(sha256: Self.abc, facts: Self.facts)
        #expect(result.map(\.source) == .success(.file(record)))
    }

    @Test func aHelperThatPrintsAnotherHashIsRefused() async throws {
        let other = String(repeating: "0", count: 64)
        let helper = try stub("echo 'sha256=\(other) audio_layers=4 text_layers=4 n_mels=80 multilingual=yes'")

        #expect(await check(helper) == .failure(.changedDuringCheck))
    }

    @Test func aHelperThatExits1GivesRefusedWithItsLine() async throws {
        let helper = try stub("echo 'Error: The model file is damaged: n_vocab -1.' >&2; exit 1")

        #expect(await check(helper) == .failure(.refused("The model file is damaged: n_vocab -1.")))
    }

    @Test func aMissingHelperGivesHelperMissing() async throws {
        let helper = folder.url.appending(path: "no-helper")

        #expect(await check(helper) == .failure(.helperMissing(path: helper.path)))
    }

    /// A file with no execute permission: `Process.run()` throws.
    @Test func aHelperThatDoesNotStartGivesHelperNotStarted() async throws {
        let helper = try stub("echo '\(Self.passLine)'", mode: 0o644)

        let result = await check(helper)

        guard case .failure(.helperNotStarted(let path, _, _)) = result else {
            Issue.record("result \(result)")
            return
        }
        #expect(path == helper.path)
    }

    /// The SHA-256 of `passed` gives the checked model with no helper run.
    @Test func aKnownHashRunsNoHelper() async throws {
        let ran = folder.url.appending(path: "ran")
        let helper = try stub("touch '\(ran.path)'; echo '\(Self.passLine)'")
        let record = PassedModelFile(sha256: Self.abc, facts: Self.facts)

        let result = await check(helper, passed: record)

        #expect(result.map(\.source) == .success(.file(record)))
        #expect(!FileManager.default.fileExists(atPath: ran.path))
    }

    /// A one-byte change of the file runs the helper again.
    @Test func aChangedFileRunsTheHelper() async throws {
        let ran = folder.url.appending(path: "ran")
        let helper = try stub("touch '\(ran.path)'; exit 1")
        try Data("abd".utf8).write(to: model)

        let result = await check(helper, passed: PassedModelFile(sha256: Self.abc, facts: Self.facts))

        #expect(result == .failure(.refused("")))
        #expect(FileManager.default.fileExists(atPath: ran.path))
    }

    @Test func aMissingModelFileIsUnreadable() async throws {
        try FileManager.default.removeItem(at: model)
        let helper = try stub("echo '\(Self.passLine)'")

        #expect(await check(helper) == .failure(.unreadable(errno: ENOENT)))
    }

    /// The helper of the app is `Contents/Helpers/dirigible`, and the helper of the CLI is the
    /// `dirigible` beside it, also through a link to the CLI of the app. A wrong path gives
    /// `.helperMissing` on each check of the app.
    @Test func theHelperIsInTheHelpersFolderOfTheAppOrBesideTheCLI() throws {
        let contents = folder.url.appending(path: "Dirigible.app/Contents")
        let (app, cli, bin) = (
            contents.appending(path: "MacOS/Dirigible"), contents.appending(path: "Helpers/dirigible"),
            folder.url.appending(path: "bin/dirigible")
        )
        for file in [app, cli, bin] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let link = folder.url.appending(path: "link/dirigible")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)
        // Foundation drops the /private of the temporary folder, and realpath keeps it.
        let real = { (url: URL) -> String? in
            guard let path = realpath(url.path, nil) else { return nil }
            defer { free(path) }
            return String(cString: path)
        }

        #expect(real(ModelFileCheck.helper(executable: app)) == real(cli))
        #expect(real(ModelFileCheck.helper(executable: bin)) == real(bin))
        #expect(real(ModelFileCheck.helper(executable: link)) == real(cli))
    }

    @Test func aFlagSetBeforeTheRunStartsNoHelper() async throws {
        let pid = folder.url.appending(path: "pid")
        let helper = try stub("echo $$ > '\(pid.path)'; exec sleep 30")

        let result = await check(helper) { true }

        #expect(result == .failure(.stopped))
        #expect(!FileManager.default.fileExists(atPath: pid.path))
    }

    @Test func aStopEndsAHelperThatSleeps() async throws {
        let (result, pid, _) = try await stopASleepingHelper()

        #expect(result == .failure(.stopped))
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "the helper \(pid) still runs")
    }

    /// The 2 s bound of 0065 C10 from the stop to the return.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aStopEndsTheHelperWithinTwoSeconds() async throws {
        let (result, _, seconds) = try await stopASleepingHelper()

        #expect(result == .failure(.stopped))
        #expect(seconds < 2, "the stop took \(seconds) s")
    }

    /// C9: the built `dirigible` with the debug abort point dies, then the same test process
    /// checks the tiny-q5_1 fixture with the real helper.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theRealHelperDiesAndTheCallerLives() async throws {
        let tiny = try WhisperFixture.model(.tinyQ51).url
        let dirigible = Bundle(for: TemporaryFolder.self).bundleURL.deletingLastPathComponent()
            .appending(path: "dirigible")
        let aborting = try stub("DIRIGIBLE_MODEL_CHECK_ABORT=1 exec '\(dirigible.path)' \"$@\"")

        #expect(await check(aborting, file: tiny) == .failure(.helperStopped(signal: SIGABRT)))

        let passed = try await check(dirigible, file: tiny).get()
        let sha = "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7"
        #expect(passed.source == .file(PassedModelFile(sha256: sha, facts: Self.facts)))
    }

    /// A stub that writes its PID and sleeps 30 s; the stop flag is set after the PID file exists.
    private func stopASleepingHelper() async throws -> (Result<CheckedModel, ModelFileCheckError>, pid_t, Double) {
        let pidFile = folder.url.appending(path: "pid")
        let helper = try stub(
            "echo $$ > '\(pidFile.path)'.tmp; mv '\(pidFile.path)'.tmp '\(pidFile.path)'; exec sleep 30")
        let stop = StopFlag()
        let url = model
        async let result = Self.run(url, helper: helper) { stop.isSet }
        let limit = ContinuousClock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: pidFile.path) {
            guard ContinuousClock.now < limit else {
                stop.set()
                Issue.record("the helper wrote no PID file in 10 s")
                _ = await result
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(
            pid_t(
                String(decoding: Data(contentsOf: pidFile), as: UTF8.self).trimmingCharacters(
                    in: .whitespacesAndNewlines)))
        let start = ContinuousClock.now
        stop.set()
        let ended = await result
        let elapsed = ContinuousClock.now - start
        return (ended, pid, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    private func check(
        _ helper: URL, file: URL? = nil, passed: PassedModelFile? = nil,
        stop: @escaping @Sendable () -> Bool = { false }
    ) async -> Result<CheckedModel, ModelFileCheckError> {
        await Self.run(file ?? model, helper: helper, passed: passed, stop: stop)
    }

    /// `ModelFileCheck.run` on a GCD thread, as the job runs it.
    private static func run(
        _ url: URL, helper: URL, passed: PassedModelFile? = nil, stop: @escaping @Sendable () -> Bool
    ) async -> Result<CheckedModel, ModelFileCheckError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: Result { () throws(ModelFileCheckError) in
                        try ModelFileCheck.run(url, helper: helper, passed: passed, stop: stop)
                    })
            }
        }
    }

    private func stub(_ body: String, mode: Int = 0o755) throws -> URL {
        try Self.stub(body, in: folder.url, mode: mode)
    }

    /// A shell script in `folder` with `body` and the file mode `mode`.
    static func stub(_ body: String, in folder: URL, mode: Int = 0o755) throws -> URL {
        let url = folder.appending(path: "helper-\(UUID().uuidString)")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }
}
