import Foundation
import Testing
import os

@testable import DirigibleAudio

/// A loader that gives each catalog URL the bytes of a local file, in chunks of 1 MB, and counts
/// the bytes that it gave. It reads a chunk only when the store asks for one.
final class FileLoader: Sendable {
    private let files: [URL: URL]
    private let given = OSAllocatedUnfairLock(initialState: 0)

    init(_ files: [URL: URL]) { self.files = files }

    var bytesGiven: Int { given.withLock { $0 } }

    var load: WhisperModelStore.Loader {
        { url in
            guard let file = self.files[url], let handle = try? FileHandle(forReadingFrom: file) else {
                return AsyncThrowingStream { $0.finish(throwing: URLError(.fileDoesNotExist)) }
            }
            return AsyncThrowingStream {
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else {
                    try handle.close()
                    return nil
                }
                self.given.withLock { $0 += chunk.count }
                return chunk
            }
        }
    }
}

/// A loader that gives the first 1 MB of `bytes` and then holds until `release()` gives the rest or
/// `end()` ends the stream. It records the end of the stream, also an end by the store.
final class HeldLoader: Sendable {
    private let bytes: Data
    private let state = OSAllocatedUnfairLock<(AsyncThrowingStream<Data, any Error>.Continuation?, ended: Bool)>(
        initialState: (nil, false))

    init(_ bytes: Data) { self.bytes = bytes }

    var ended: Bool { state.withLock { $0.ended } }

    var load: WhisperModelStore.Loader {
        { _ in
            AsyncThrowingStream { continuation in
                continuation.onTermination = { _ in self.state.withLock { $0.ended = true } }
                continuation.yield(self.bytes.prefix(1 << 20))
                self.state.withLock { $0.0 = continuation }
            }
        }
    }

    func release() {
        guard let continuation = state.withLock({ $0.0 }) else { return }
        var offset = 1 << 20
        while offset < bytes.count {
            continuation.yield(bytes[offset..<min(offset + (1 << 20), bytes.count)])
            offset += 1 << 20
        }
        continuation.finish()
    }

    func end() { state.withLock { $0.0 }?.finish() }
}

/// A stop check that the test sets.
final class StopSwitch: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}

func fileNames(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

func fileSize(_ url: URL) -> Int? { try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize }

struct WhisperModelStoreTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aChangedByteIsRefusedAndLeavesNoFile() async throws {
        let fixture = try WhisperFixture.model(.tinyQ51)
        let source = try TemporaryFolder()
        let changed = source.url.appending(path: "changed.bin")
        var bytes = try Data(contentsOf: fixture.url)
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: changed)
        let folder = try TemporaryFolder()
        let loader = FileLoader([WhisperModel.tinyQ51.url: changed])
        let store = WhisperModelStore(folder: folder.url, load: loader.load)

        await #expect(throws: WhisperModelStoreError.checksumMismatch) {
            try await store.download(.tinyQ51, stop: { false })
        }
        #expect(loader.bytesGiven == 32_152_673, "the store read the whole file")
        #expect(try fileNames(folder.url) == [])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aGoodFileLandsAtItsCatalogName() async throws {
        let fixture = try WhisperFixture.model(.tinyQ51)
        let temporary = try TemporaryFolder()
        let folder = temporary.url.appending(path: "Models")
        let store = WhisperModelStore(folder: folder, load: FileLoader([WhisperModel.tinyQ51.url: fixture.url]).load)

        try await store.download(.tinyQ51, stop: { false })

        #expect(try fileNames(folder) == ["ggml-tiny-q5_1.bin"])
        #expect(WhisperModel.tinyQ51.checked(in: folder) != nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theModelFileIsExcludedFromBackup() async throws {
        let fixture = try WhisperFixture.model(.tinyQ51)
        let folder = try TemporaryFolder()
        let store = WhisperModelStore(
            folder: folder.url, load: FileLoader([WhisperModel.tinyQ51.url: fixture.url]).load)

        try await store.download(.tinyQ51, stop: { false })

        let model = folder.url.appending(path: "ggml-tiny-q5_1.bin")
        #expect(try model.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    /// The progress of a download is the received bytes over the catalog byte count, after each
    /// chunk.
    @Test func aDownloadReportsTheReceivedBytes() async throws {
        let source = try TemporaryFolder()
        let bytes = source.url.appending(path: "zeros.bin")
        try Data(count: 3 << 20).write(to: bytes)
        let folder = try TemporaryFolder()
        let store = WhisperModelStore(folder: folder.url, load: FileLoader([WhisperModel.tinyQ51.url: bytes]).load)
        let fractions = OSAllocatedUnfairLock<[Double]>(initialState: [])

        await #expect(throws: WhisperModelStoreError.checksumMismatch) {
            try await store.download(
                .tinyQ51, stop: { false }, progress: { fraction in fractions.withLock { $0.append(fraction) } })
        }

        let total = Double(WhisperModel.tinyQ51.byteCount)
        let expected: [Double] = [1, 2, 3].map { Double($0 << 20) / total }
        #expect(fractions.withLock { $0 } == expected)
    }

    @Test func aCancelAtHalfLeavesNoFile() async throws {
        let source = try TemporaryFolder()
        let bytes = source.url.appending(path: "zeros.bin")
        try Data(count: WhisperModel.tinyQ51.byteCount).write(to: bytes)
        let folder = try TemporaryFolder()
        let temporary = folder.url.appending(path: "ggml-tiny-q5_1.bin.download")
        let loader = FileLoader([WhisperModel.tinyQ51.url: bytes])
        let store = WhisperModelStore(folder: folder.url, load: loader.load)
        let sizeAtStop = OSAllocatedUnfairLock<Int?>(initialState: nil)

        await #expect(throws: WhisperModelStoreError.stopped) {
            try await store.download(.tinyQ51) {
                guard loader.bytesGiven >= WhisperModel.tinyQ51.byteCount / 2 else { return false }
                sizeAtStop.withLock { $0 = $0 ?? fileSize(temporary) }
                return true
            }
        }
        #expect(sizeAtStop.withLock { $0 } == 15 << 20, "15 chunks were on disk when the stop turned true")
        #expect(loader.bytesGiven == 16 << 20, "the store asked for no chunk after the stop")
        #expect(try fileNames(folder.url) == [])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aStalledLoaderShowsNoFinalName() async throws {
        let fixture = try WhisperFixture.model(.tinyQ51)
        let folder = try TemporaryFolder()
        let loader = HeldLoader(try Data(contentsOf: fixture.url))
        let store = WhisperModelStore(folder: folder.url, load: loader.load)
        let temporary = folder.url.appending(path: "ggml-tiny-q5_1.bin.download")

        let download = Task { try await store.download(.tinyQ51, stop: { false }) }
        await until(limit: .seconds(5), "chunk 1 is on disk") { fileSize(temporary) == 1 << 20 }
        #expect(try fileNames(folder.url) == ["ggml-tiny-q5_1.bin.download"])
        loader.release()
        try await download.value

        #expect(try fileNames(folder.url) == ["ggml-tiny-q5_1.bin"])
    }

    @Test func aStopDuringAStallDeletesTheTemporaryFile() async throws {
        let folder = try TemporaryFolder()
        let loader = HeldLoader(Data(count: 2 << 20))
        let store = WhisperModelStore(folder: folder.url, load: loader.load)
        let temporary = folder.url.appending(path: "ggml-tiny-q5_1.bin.download")
        let stop = StopSwitch()

        let download = Task { try await store.download(.tinyQ51, stop: { stop.isSet }) }
        await until(limit: .seconds(5), "chunk 1 is on disk") { fileSize(temporary) == 1 << 20 }
        stop.set()
        let start = ContinuousClock.now
        // A store that waits for a chunk throws only when the stream ends. The limit is 3 times the
        // worst stop to throw with 11 other suites in the process: 3.83 s (run whisper-in-app, S5).
        let endedByTest = StopSwitch()
        let limit = Task {
            try await Task.sleep(for: .seconds(12))
            endedByTest.set()
            loader.end()
        }
        defer { limit.cancel() }
        let result = await download.result
        let elapsed = ContinuousClock.now - start

        #expect(!endedByTest.isSet, "the store threw before the test ended the stream (\(elapsed))")
        #expect(throws: WhisperModelStoreError.stopped) { try result.get() }
        #expect(loader.ended, "the store ended the stream")
        #expect(try fileNames(folder.url) == [])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aLeftoverTemporaryFileIsRemoved() async throws {
        let fixture = try WhisperFixture.model(.base)
        let folder = try TemporaryFolder()
        try Data(count: 1 << 20).write(to: folder.url.appending(path: "ggml-small-q5_1.bin.download"))
        let store = WhisperModelStore(folder: folder.url, load: FileLoader([WhisperModel.base.url: fixture.url]).load)
        #expect(try fileNames(folder.url) == ["ggml-small-q5_1.bin.download"])

        try store.removeLeftovers()
        try await store.download(.base, stop: { false })

        #expect(try fileNames(folder.url) == ["ggml-base.bin"])
    }
}
