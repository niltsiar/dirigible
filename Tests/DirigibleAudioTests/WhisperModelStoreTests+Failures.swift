import Foundation
import Testing
import os

@testable import DirigibleAudio

/// A server on 127.0.0.1 that answers each request with one canned HTTP response: a status line,
/// `Content-Length`, `Connection: close`, and `sent` zero bytes of the body. It closes the socket
/// after the bytes, so a `sent` under `length` is a connection that drops in the body. The real
/// `URLSession` and `ChunkDelegate` of the store talk to it.
final class LoopbackServer: Sendable {
    let port: UInt16
    private let listener: Int32
    private let closed = OSAllocatedUnfairLock(initialState: false)
    private let served = OSAllocatedUnfairLock(initialState: 0)

    var url: URL { URL(string: "http://127.0.0.1:\(port)/model.bin")! }
    var requests: Int { served.withLock { $0 } }

    init(status: Int = 200, length: Int, sent: Int) {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(listener, $0, size)
                _ = listen(listener, 8)
                var length = size
                _ = getsockname(listener, $0, &length)
            }
        }
        (self.listener, port) = (listener, UInt16(bigEndian: address.sin_port))
        let head = Data("HTTP/1.1 \(status) Canned\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n".utf8)
        Thread.detachNewThread { [self] in serve(head: head, sent: sent) }
    }

    func close() {
        closed.withLock { $0 = true }
    }

    private func serve(head: Data, sent: Int) {
        var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        while !closed.withLock({ $0 }) {
            guard poll(&ready, 1, 100) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            var off: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &off, socklen_t(MemoryLayout<Int32>.size))
            var request = [UInt8](repeating: 0, count: 4096)
            _ = read(client, &request, request.count)
            served.withLock { $0 += 1 }
            send(head, to: client)
            send(Data(count: sent), to: client)
            Darwin.close(client)
        }
        Darwin.close(listener)
    }

    /// Writes all of `bytes`, or stops at the first error (the client cancelled the request).
    private func send(_ bytes: Data, to client: Int32) {
        var offset = 0
        bytes.withUnsafeBytes { buffer in
            while offset < buffer.count {
                let count = write(client, buffer.baseAddress! + offset, buffer.count - offset)
                guard count > 0 else { return }
                offset += count
            }
        }
    }
}

extension WhisperModelStoreTests {
    struct Download {
        let error: (any Error)?
        let gotBytes: Bool
        let files: [String]
        let mapped: TranscribeError?
    }

    /// One `download` of `.tinyQ51` from `server` through the live `URLSession` loader.
    static func download(from server: LoopbackServer) async throws -> Download {
        let folder = try TemporaryFolder()
        let store = WhisperModelStore(folder: folder.url) { _ in WhisperModelStore.live.load(server.url) }
        let activity = DownloadActivity()
        var thrown: (any Error)?
        do { try await store.download(.tinyQ51, stop: { false }, activity: activity) } catch { thrown = error }
        return Download(
            error: thrown, gotBytes: activity.lastChunk != nil, files: try fileNames(folder.url),
            mapped: thrown.map { modelError($0, folder: folder.url) })
    }

    /// A status other than 200 ends the download with `.badServerResponse` before any body byte; a
    /// 200 with a short body is the near input, which ends in the checksum check.
    @Test(arguments: [
        (404, 5, true), (500, 1000, true), (503, 0, true), (200, 1 << 20, false),
    ])
    func aStatusOtherThan200EndsTheDownloadWithNoFile(status: Int, body: Int, isError: Bool) async throws {
        let server = LoopbackServer(status: status, length: body, sent: body)
        defer { server.close() }

        let result = try await Self.download(from: server)

        if isError {
            #expect((result.error as? URLError)?.code == .badServerResponse, "\(String(describing: result.error))")
            #expect(result.mapped == .modelDownload)
            #expect(!result.gotBytes)
        } else {
            #expect(result.error as? WhisperModelStoreError == .checksumMismatch)
            #expect(result.mapped == .modelDownloadChecksum)
            #expect(result.gotBytes)
        }
        #expect(server.requests == 1)
        #expect(result.files == [])
    }

    /// A connection that drops after 3 chunks ends the download with the network error, deletes
    /// the file that held 3 MB, and the next call starts at byte 0. A clean end is the near input.
    @Test func aConnectionLostAfterChunksLeavesNoFileAndTheNextCallStartsAtByteZero() async throws {
        let folder = try TemporaryFolder()
        let temporary = folder.url.appending(path: "ggml-tiny-q5_1.bin.download")
        let sizeAtChunk4 = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let lost = WhisperModelStore(folder: folder.url) { _ in
            let asked = OSAllocatedUnfairLock(initialState: 0)
            return AsyncThrowingStream {
                guard
                    asked.withLock({
                        $0 += 1
                        return $0
                    }) > 3
                else { return Data(count: 1 << 20) }
                sizeAtChunk4.withLock { $0 = fileSize(temporary) }
                throw URLError(.networkConnectionLost)
            }
        }
        var thrown: (any Error)?
        do { try await lost.download(.tinyQ51, stop: { false }) } catch { thrown = error }

        #expect((thrown as? URLError)?.code == .networkConnectionLost, "\(String(describing: thrown))")
        #expect(thrown.map { modelError($0, folder: folder.url) } == .modelDownload)
        #expect(sizeAtChunk4.withLock { $0 } == 3 << 20, "the file held 3 chunks, so the empty folder is a deletion")
        #expect(try fileNames(folder.url) == [])

        let loader = HeldLoader(Data(count: 2 << 20))
        let next = WhisperModelStore(folder: folder.url, load: loader.load)
        let download = Task { try await next.download(.tinyQ51, stop: { false }) }
        await until(limit: .seconds(5), "chunk 1 of the second call is on disk") { fileSize(temporary) == 1 << 20 }
        loader.end()
        await #expect(throws: WhisperModelStoreError.checksumMismatch) { try await download.value }
        #expect(try fileNames(folder.url) == [])

        let clean = WhisperModelStore(folder: folder.url) { _ in
            let asked = OSAllocatedUnfairLock(initialState: 0)
            return AsyncThrowingStream {
                asked.withLock({
                    $0 += 1
                    return $0
                }) > 3 ? nil : Data(count: 1 << 20)
            }
        }
        var ended: (any Error)?
        do { try await clean.download(.tinyQ51, stop: { false }) } catch { ended = error }
        #expect(ended as? WhisperModelStoreError == .checksumMismatch)
        #expect(ended.map { modelError($0, folder: folder.url) } == .modelDownloadChecksum)
        #expect(try fileNames(folder.url) == [])
    }

    /// The real `URLSession` path: a server that closes the socket in the body ends the download
    /// with a network error after the first bytes. The whole body is the near input.
    @Test(arguments: [(1 << 20, true), (3 << 20, false)])
    func aServerThatClosesMidBodyEndsTheDownloadWithNoFile(sent: Int, drops: Bool) async throws {
        let server = LoopbackServer(length: 3 << 20, sent: sent)
        defer { server.close() }

        let result = try await Self.download(from: server)

        if drops {
            #expect((result.error as? URLError)?.code == .networkConnectionLost, "\(String(describing: result.error))")
            #expect(result.mapped == .modelDownload)
        } else {
            #expect(result.error as? WhisperModelStoreError == .checksumMismatch)
            #expect(result.mapped == .modelDownloadChecksum)
        }
        #expect(result.gotBytes)
        #expect(result.files == [])
    }
}
