import CryptoKit
import Foundation

/// A model file, opened once for reading (decision 0065, D8). Only a regular file opens: the open
/// of a FIFO waits for a writer, and a read of a device can have no end.
final class OpenModelFile: Sendable {
    let descriptor: Int32

    /// The bytes of one read: a stop check runs before each of them.
    static let chunk = 1 << 20

    init(_ url: URL) throws(ModelFileCheckError) {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw .unreadable(errno: errno) }
        var status = stat()
        let code = fstat(descriptor, &status) != 0 ? errno : status.st_mode & S_IFMT == S_IFREG ? 0 : EFTYPE
        guard code == 0 else {
            close(descriptor)
            throw .unreadable(errno: code)
        }
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    /// The SHA-256 of the file in lowercase hex, to the end of the file. It reads `stop` before each
    /// `chunk`, and a set stop throws `.stopped`.
    func sha256(stop: () -> Bool) throws(ModelFileCheckError) -> String {
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: Self.chunk)
        var offset: off_t = 0
        while true {
            if stop() { throw .stopped }
            let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, offset) }
            if count < 0 {
                if errno == EINTR { continue }
                throw .unreadable(errno: errno)
            }
            if count == 0 { break }
            buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
            offset += off_t(count)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
