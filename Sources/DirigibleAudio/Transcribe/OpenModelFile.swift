import CWhisper
import CryptoKit
import Foundation
import os

/// A model file, opened once for reading (decision 0065, D8). Only a regular file opens: the open
/// of a FIFO waits for a writer, and a read of a device can have no end. The hash, the helper, and
/// the engine read this one descriptor, so a rename over the path cannot give them other bytes.
final class OpenModelFile: Sendable {
    let descriptor: Int32
    #if DEBUG
        private let counted = OSAllocatedUnfairLock(initialState: 0)
        /// The bytes that this process read from the file, for the tests of the read count.
        var bytesRead: Int { counted.withLock { $0 } }
    #endif

    /// The bytes of one read: a stop check runs before each of them.
    static let chunk = 1 << 20

    convenience init(_ url: URL) throws(ModelFileCheckError) {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw .unreadable(errno: errno) }
        try self.init(descriptor: descriptor)
    }

    /// Takes `descriptor`, and closes it also when the file is not a regular file.
    init(descriptor: Int32) throws(ModelFileCheckError) {
        var status = stat()
        let code = fstat(descriptor, &status) != 0 ? errno : status.st_mode & S_IFMT == S_IFREG ? 0 : EFTYPE
        guard code == 0 else {
            close(descriptor)
            throw .unreadable(errno: code)
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    /// `pread` on the file: the one read path of the hash and the engine load.
    func read(into buffer: UnsafeMutableRawPointer, count: Int, at offset: off_t) -> Int {
        let got = pread(descriptor, buffer, count, offset)
        #if DEBUG
            if got > 0 { counted.withLock { $0 += got } }
        #endif
        return got
    }

    /// The SHA-256 of the file in lowercase hex, to the end of the file. It reads `stop` before each
    /// `chunk`, and a set stop throws `.stopped`.
    func sha256(stop: () -> Bool) throws(ModelFileCheckError) -> String {
        var hash = SHA256()
        try hashRest(&hash, from: 0, stop: stop)
        return hash.finalize().hex
    }

    /// Adds the bytes from `offset` to the end of the file to `hash`, with the stop check of
    /// `sha256(stop:)`.
    func hashRest(_ hash: inout SHA256, from offset: off_t, stop: () -> Bool) throws(ModelFileCheckError) {
        var buffer = [UInt8](repeating: 0, count: Self.chunk)
        var offset = offset
        while true {
            if stop() { throw .stopped }
            let count = buffer.withUnsafeMutableBytes { read(into: $0.baseAddress!, count: $0.count, at: offset) }
            if count < 0 {
                if errno == EINTR { continue }
                throw .unreadable(errno: errno)
            }
            if count == 0 { return }
            buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            offset += off_t(count)
        }
    }
}

/// The identity of the open file: two checks of one path are two open files.
extension OpenModelFile: Hashable {
    static func == (lhs: OpenModelFile, rhs: OpenModelFile) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

extension SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// The `whisper_model_loader` of an `OpenModelFile` (decision 0065, D8): `pread` from byte 0, the
/// SHA-256 of each byte that whisper.cpp gets, and the stop of the job. The load compares that
/// SHA-256 with the record of the check before the context is used.
final class ModelFileLoad {
    /// The magic and the 11 hparams. whisper.cpp aborts on zero hparams, so they come from a read
    /// before the load, and a stop or a read error holds only after them.
    static let headerCount = 48

    private let file: OpenModelFile
    private let stop: StopFlag
    private var header = [UInt8](repeating: 0, count: headerCount)
    private var offset = 0
    private var hash = SHA256()
    private var eof = false
    private var stopped = false
    private var failure: Int32?

    init(_ file: OpenModelFile, stop: StopFlag) {
        (self.file, self.stop) = (file, stop)
    }

    /// The context of the file, when the bytes that whisper.cpp loaded have the SHA-256 `sha256`.
    /// A stop throws `.modelLoad`, a read error `.modelFile(.unreadable)`, and other bytes
    /// `.modelChanged`. Each throw frees the context.
    func load(_ params: whisper_context_params, sha256: String) throws(TranscribeError) -> OpaquePointer {
        var filled = 0
        while filled < Self.headerCount {
            let count = header.withUnsafeMutableBytes {
                file.read(into: $0.baseAddress! + filled, count: Self.headerCount - filled, at: off_t(filled))
            }
            if count < 0, errno == EINTR { continue }
            if count < 0 { throw .modelFile(.unreadable(errno: errno)) }
            // The file passed its check with more bytes, so it changed.
            if count == 0 { throw .modelChanged }
            filled += count
        }
        var loader = whisper_model_loader()
        loader.context = Unmanaged.passUnretained(self).toOpaque()
        loader.read = { context, output, size in
            guard let context, let output else { return 0 }
            return Unmanaged<ModelFileLoad>.fromOpaque(context).takeUnretainedValue().read(output, size)
        }
        loader.eof = { context in
            guard let context else { return true }
            return Unmanaged<ModelFileLoad>.fromOpaque(context).takeUnretainedValue().eof
        }
        loader.close = { _ in }
        let context = withExtendedLifetime(self) { whisper_init_with_params(&loader, params) }
        do throws(TranscribeError) {
            if stopped { throw .modelLoad }
            if let failure { throw .modelFile(.unreadable(errno: failure)) }
            do throws(ModelFileCheckError) { try file.hashRest(&hash, from: off_t(offset)) { stop.isSet } } catch {
                throw error == .stopped ? .modelLoad : .modelFile(error)
            }
            guard hash.finalize().hex == sha256 else { throw .modelChanged }
            guard let context else { throw .modelLoad }
            return context
        } catch {
            if let context { whisper_free(context) }
            throw error
        }
    }

    /// One read of whisper.cpp: `size` bytes, or fewer at the end of the file. After a stop or a
    /// read error, it gives zeros and sets eof, so the load ends with no abort.
    private func read(_ output: UnsafeMutableRawPointer, _ size: Int) -> Int {
        var done = 0
        while done < size {
            if offset < Self.headerCount {
                let count = min(size - done, Self.headerCount - offset)
                header.withUnsafeBytes { (output + done).copyMemory(from: $0.baseAddress! + offset, byteCount: count) }
                hash.update(bufferPointer: UnsafeRawBufferPointer(start: output + done, count: count))
                (offset, done) = (offset + count, done + count)
                continue
            }
            if stop.isSet { stopped = true }
            if stopped || failure != nil {
                (output + done).initializeMemory(as: UInt8.self, repeating: 0, count: size - done)
                eof = true
                return size
            }
            let count = file.read(into: output + done, count: min(size - done, OpenModelFile.chunk), at: off_t(offset))
            if count < 0 {
                if errno != EINTR { failure = errno }
                continue
            }
            if count == 0 {
                eof = true
                return done
            }
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: output + done, count: count))
            (offset, done) = (offset + count, done + count)
        }
        return done
    }
}
