import Foundation
import Testing
import os

@testable import DirigibleAudio

/// The reads of a model file of the user in `ModelFileCheck` (decision 0065, D8): only a regular
/// file opens, a stop ends a hash at the next chunk, the helper reads the file that `run` opened,
/// a record of another check version runs the helper, and a helper ends when its parent exits.
struct ModelFileReadTests {
    typealias Check = ModelFileCheckTests

    let folder: TemporaryFolder
    let model: URL

    init() throws {
        folder = try TemporaryFolder()
        model = folder.url.appending(path: "model.bin")
        try Data("abc".utf8).write(to: model)
    }

    enum Special: CaseIterable { case fifo, device }

    /// Only a regular file opens: the open of a FIFO waits for a writer, and a read of /dev/zero
    /// has no end. Both are refused at once with EFTYPE, and no helper runs.
    @Test(arguments: Special.allCases) func aFileThatIsNotRegularIsRefusedAtOnce(special: Special) async throws {
        let ran = folder.url.appending(path: "ran")
        let helper = try stub("touch '\(ran.path)'; echo '\(Check.passLine)'")
        let url: URL
        switch special {
        case .fifo:
            url = folder.url.appending(path: "fifo")
            #expect(mkfifo(url.path, 0o644) == 0)
        case .device: url = URL(filePath: "/dev/zero")
        }
        let passed = PassedModelFile(sha256: Check.abc, facts: Check.facts)
        let ended = OSAllocatedUnfairLock<Result<CheckedModel, ModelFileCheckError>?>(initialState: nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws(ModelFileCheckError) in
                try ModelFileCheck.run(url, helper: helper, passed: passed) { false }
            }
            ended.withLock { $0 = result }
        }

        await until(limit: .seconds(5), "the check of \(url.path) returns") { ended.withLock { $0 } != nil }

        if special == .fifo {
            // A writer ends an open that waits on the FIFO.
            let writer = open(url.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
        }
        #expect(ended.withLock { $0 } == .failure(.unreadable(errno: EFTYPE)))
        #expect(!FileManager.default.fileExists(atPath: ran.path))
    }

    /// A stop during the hash ends the run at the next 1 MiB chunk: a stop that is set at its third
    /// read ends the hash of a 64 MiB file there. The helper path has no file, so a stop check that
    /// comes only after the hash gives `.helperMissing`.
    @Test func aStopDuringTheHashEndsTheRunAtTheNextChunk() async throws {
        let big = folder.url.appending(path: "big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        #expect(truncate(big.path, 64 << 20) == 0)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let passed = PassedModelFile(sha256: Check.abc, facts: Check.facts)

        let result = await Self.run(big, helper: folder.url.appending(path: "no-helper"), passed: passed) {
            reads.withLock {
                $0 += 1
                return $0 >= 3
            }
        }

        #expect(result == .failure(.stopped))
        #expect(reads.withLock { $0 } == 3)
    }

    /// The helper gets `-` as its path and the file that `run` opened as its standard input, so a
    /// rename over the path after the open cannot give the helper other bytes.
    @Test func theHelperReadsTheOpenFileOnItsStandardInput() async throws {
        let (arguments, input) = (folder.url.appending(path: "arguments"), folder.url.appending(path: "input"))
        let helper = try stub(
            "echo \"$@\" > '\(arguments.path)'; if [ \"$3\" = - ]; then cat > '\(input.path)'; fi; "
                + "echo '\(Check.passLine)'")

        let result = await Self.run(model, helper: helper)

        #expect(result.map(\.source) == .success(.file(PassedModelFile(sha256: Check.abc, facts: Check.facts))))
        #expect(try String(contentsOf: arguments, encoding: .utf8) == "model check -\n")
        #expect(try Data(contentsOf: input) == Data("abc".utf8))
    }

    /// A record of another check version counts as not passed: the helper runs, and the new record
    /// has the version of this check.
    @Test func aRecordOfAnotherCheckVersionRunsTheHelper() async throws {
        let ran = folder.url.appending(path: "ran")
        let helper = try stub("touch '\(ran.path)'; echo '\(Check.passLine)'")
        let old = PassedModelFile(sha256: Check.abc, facts: Check.facts, check: ModelFileCheck.version - 1)

        let result = await Self.run(model, helper: helper, passed: old)

        #expect(result.map(\.source) == .success(.file(PassedModelFile(sha256: Check.abc, facts: Check.facts))))
        #expect(FileManager.default.fileExists(atPath: ran.path))
    }

    /// A helper whose parent exits ends within 1 s, so an app crash or a Force Quit leaves no trial
    /// that runs beside the next take. The parent is a shell that starts the built `dirigible` with a
    /// trial that does not end, and exits when the helper prints that its exit watch runs: the 1 s
    /// starts after the helper start, which a loaded test run makes slow.
    @Test func aHelperEndsWithinOneSecondWhenItsParentExits() throws {
        let dirigible = Bundle(for: TemporaryFolder.self).bundleURL.deletingLastPathComponent()
            .appending(path: "dirigible")
        let (pidFile, ready) = (folder.url.appending(path: "pid"), folder.url.appending(path: "ready"))
        let parent = try stub(
            "mkfifo '\(ready.path)'; "
                + "DIRIGIBLE_MODEL_CHECK_HOLD=1 '\(dirigible.path)' model check '\(model.path)' > '\(ready.path)' & "
                + "echo $! > '\(pidFile.path)'; read line < '\(ready.path)' && [ \"$line\" = hold ]")
        let process = Process()
        process.executableURL = parent
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "the helper printed no hold line")
        let pid = try #require(
            pid_t(String(decoding: Data(contentsOf: pidFile), as: UTF8.self).trimmingCharacters(in: .newlines)))
        defer { kill(pid, SIGKILL) }

        let limit = ContinuousClock.now + .seconds(1)
        while kill(pid, 0) == 0, ContinuousClock.now < limit { usleep(10_000) }

        #expect(kill(pid, 0) == -1 && errno == ESRCH, "the helper \(pid) still runs")
    }

    private func stub(_ body: String) throws -> URL { try Check.stub(body, in: folder.url) }

    /// `ModelFileCheck.run` on a GCD thread, as the job runs it.
    private static func run(
        _ url: URL, helper: URL, passed: PassedModelFile? = nil, stop: @escaping @Sendable () -> Bool = { false }
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
}
