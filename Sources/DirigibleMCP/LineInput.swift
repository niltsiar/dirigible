import Foundation

/// The stdin lines of `dirigible mcp`, read with no stdio buffer, so the bridge can watch stdin
/// while a call waits for the app (decision 0048). One thread uses it.
package final class LineInput {
    let fd: Int32
    private var buffer = Data()
    private var bytes = [UInt8](repeating: 0, count: readSize)
    /// True after EOF or a read error.
    private(set) var ended = false
    /// The JSON-RPC `id` of the last line that `next` gave, or nil.
    private var current: NSObject?

    package init(fd: Int32 = STDIN_FILENO) { self.fd = fd }

    /// The next line with no `\n` or `\r\n`, as `readLine` gives it, or nil at the end.
    package func next() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                var line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
                current = Self.object(line)?["id"] as? NSObject
                return String(decoding: line, as: UTF8.self)
            }
            if ended {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                current = Self.object(buffer)?["id"] as? NSObject
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

    /// True when stdin ended, or a buffered line cancels the request of the last line: the agent
    /// no longer waits for that call.
    func stopsCall() -> Bool {
        if ended { return true }
        guard let current else { return false }
        return buffer.split(separator: UInt8(ascii: "\n")).contains { line in
            guard let message = Self.object(line), message["method"] as? String == "notifications/cancelled",
                let params = message["params"] as? [String: Any]
            else { return false }
            return (params["requestId"] as? NSObject)?.isEqual(current) == true
        }
    }

    private static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}
