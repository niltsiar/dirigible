import Foundation

/// The stdin lines of `dirigible mcp`, read with no stdio buffer, so a running call can read a
/// cancel on stdin (decisions 0048 and 0049). One thread uses it.
package final class LineInput {
    let fd: Int32
    private var buffer = Data()
    private var bytes = [UInt8](repeating: 0, count: readSize)
    /// True after EOF or a read error.
    private(set) var ended = false

    package init(fd: Int32 = STDIN_FILENO) { self.fd = fd }

    /// The next line with no `\n` or `\r\n`, as `readLine` gives it, or nil at the end.
    package func next() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
                return String(decoding: line, as: UTF8.self)
            }
            if ended {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return String(decoding: buffer, as: UTF8.self)
            }
            fill()
        }
    }

    /// Reads once into the buffer. Call it when a poll says that `fd` is readable.
    func fill() {
        let count = read(fd, &bytes, readSize)
        if count < 0, errno == EINTR { return }
        guard count > 0 else {
            ended = true
            return
        }
        buffer.append(contentsOf: bytes[..<count])
    }

    /// With `read`, reads stdin after a poll of 0 ms. Gives true when a buffered line cancels
    /// `requestID` (decision 0049). After EOF it reads nothing: EOF ends only a `record` call
    /// (decision 0048).
    package func pollCancel(_ requestID: NSObject, read: Bool = true) -> Bool {
        if read, !ended {
            var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&entry, 1, 0) > 0 { fill() }
        }
        return cancels(requestID)
    }

    /// True when a buffered `notifications/cancelled` names `requestID`.
    private func cancels(_ requestID: NSObject) -> Bool {
        buffer.split(separator: UInt8(ascii: "\n")).contains { line in
            guard let message = Self.object(line), message["method"] as? String == "notifications/cancelled",
                let params = message["params"] as? [String: Any]
            else { return false }
            return (params["requestId"] as? NSObject)?.isEqual(requestID) == true
        }
    }

    private static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}
