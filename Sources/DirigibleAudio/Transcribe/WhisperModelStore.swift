import Foundation
import os

/// The model folder and the download of a catalog model (decision 0065, D2). A download writes
/// `<file name>.download`, checks that file with `WhisperModel.checked(at:)`, and only then renames
/// it to the catalog file name, so no model load reads a partial or changed file.
public struct WhisperModelStore: Sendable {
    /// Gives the chunks of a URL. The store ends the stream on a stop.
    public typealias Loader = @Sendable (URL) -> AsyncThrowingStream<Data, any Error>

    public let folder: URL
    let load: Loader

    public init(folder: URL, load: @escaping Loader) {
        self.folder = folder
        self.load = load
    }

    /// The folder of `folder(environment:)` and the `URLSession` loader: the one network user of
    /// the app (C5).
    public static var live: WhisperModelStore { WhisperModelStore(folder: folder(), load: urlSessionChunks) }

    /// `DIRIGIBLE_MODELS_FOLDER` when it is set, else `~/Library/Application Support/Dirigible/Models`.
    public static func folder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["DIRIGIBLE_MODELS_FOLDER"], !path.isEmpty {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return URL.applicationSupportDirectory.appending(path: "Dirigible/Models", directoryHint: .isDirectory)
    }

    /// Deletes each `*.download` file in the folder: what a crash or a force quit left of a download.
    public func removeLeftovers() throws {
        let files = FileManager.default
        guard files.fileExists(atPath: folder.path) else { return }
        for name in try files.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".download") {
            try files.removeItem(at: folder.appending(path: name))
        }
    }

    /// Downloads `model` from its catalog URL to its catalog file name in the folder. It reads
    /// `stop` at each chunk, and every 0.25 s while it waits for a chunk. A set stop ends the stream
    /// and throws `.stopped`; a file that fails the catalog check throws `.checksumMismatch`; a
    /// stream that ends with `URLError.timedOut` before the first byte throws `.noData`. Each throw
    /// deletes the temporary file. The next call downloads again from byte 0. `activity` gets the
    /// instant of each chunk; `progress` gets the received bytes over the catalog byte count.
    @concurrent public func download(
        _ model: WhisperModel, stop: @escaping @Sendable () -> Bool, activity: DownloadActivity = DownloadActivity(),
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        var temporary = folder.appending(path: model.fileName + ".download")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try temporary.setResourceValues(values)
            try await Self.write(
                load(model.url), to: temporary, total: model.byteCount, host: model.url.host()!, stop: stop,
                activity: activity, progress: progress)
            guard model.checked(at: temporary) != nil else { throw WhisperModelStoreError.checksumMismatch }
            guard rename(temporary.path, folder.appending(path: model.fileName).path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? files.removeItem(at: temporary)
            throw error
        }
    }

    /// Appends each chunk to `file` until the stream ends, and gives `progress` the byte count so
    /// far over `total` when its whole percent grows: at most 101 main-actor hops per download. A
    /// second task reads `stop` every 0.25 s, so a stall of the loader does not hide a stop.
    private static func write(
        _ chunks: AsyncThrowingStream<Data, any Error>, to file: URL, total: Int, host: String,
        stop: @escaping @Sendable () -> Bool, activity: DownloadActivity, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                var (count, reported) = (0, -1)
                do {
                    for try await chunk in chunks {
                        guard !stop() else { throw WhisperModelStoreError.stopped }
                        try handle.write(contentsOf: chunk)
                        count += chunk.count
                        activity.chunk()
                        let fraction = Double(count) / Double(total)
                        guard Int(fraction * 100) > reported else { continue }
                        reported = Int(fraction * 100)
                        progress(fraction)
                    }
                } catch let error as URLError where error.code == .timedOut && count == 0 {
                    throw WhisperModelStoreError.noData(host: host)
                }
                // The stream gives no error when the stop task cancels this task.
                try Task.checkCancellation()
            }
            group.addTask {
                while !stop() { try await Task.sleep(for: .milliseconds(250)) }
                throw WhisperModelStoreError.stopped
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    /// The chunks of `url` from one `URLSession` request. A response other than HTTP 200 throws
    /// `URLError(.badServerResponse)`. The end of the stream cancels the request.
    private static let urlSessionChunks: Loader = { url in
        AsyncThrowingStream { continuation in
            let session = URLSession(
                configuration: .ephemeral, delegate: ChunkDelegate(continuation), delegateQueue: nil)
            continuation.onTermination = { _ in session.invalidateAndCancel() }
            session.dataTask(with: url).resume()
        }
    }
}

public enum WhisperModelStoreError: Error, Hashable, Sendable {
    /// The downloaded file does not have the byte count and the SHA-256 of the catalog.
    case checksumMismatch
    /// The stop check turned true during the download.
    case stopped
    /// The request limit ended the download before the first byte from this host.
    case noData(host: String)
}

/// The instant of the last chunk of a download, for the firewall hint of the window (decision
/// 0065). The download task writes it with one lock per chunk and no main-actor call.
public final class DownloadActivity: Sendable {
    private struct State {
        var last: ContinuousClock.Instant?
        var next: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    /// Nil before the first chunk.
    public var lastChunk: ContinuousClock.Instant? { state.withLock { $0.last } }

    /// Arms `body` when no chunk came after `seen`: the next chunk runs it once, on the download
    /// task. False when a chunk came after `seen`; then nothing is armed.
    public func onNextChunk(ifNoChunkSince seen: ContinuousClock.Instant?, _ body: @escaping @Sendable () -> Void)
        -> Bool
    {
        state.withLock { state in
            guard state.last == seen else { return false }
            state.next = body
            return true
        }
    }

    /// Records a chunk now and runs the armed body, outside the lock.
    func chunk() {
        let next = state.withLock { state in
            defer { state.next = nil }
            state.last = .now
            return state.next
        }
        next?()
    }
}

private final class ChunkDelegate: NSObject, URLSessionDataDelegate, Sendable {
    let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    init(_ continuation: AsyncThrowingStream<Data, any Error>.Continuation) { self.continuation = continuation }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            continuation.finish(throwing: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        continuation.finish(throwing: error)
    }
}
