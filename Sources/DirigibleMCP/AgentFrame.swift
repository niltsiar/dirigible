import Foundation

// The frames between the `dirigible mcp` bridge and the app server (decision 0046): one JSON
// object on one line in each direction.
//
// A call:  {"tool": <name>, "arguments": {...}, "client": {"title": <text>, "name": <text>}}
// A reply: {"text": <text>, "isError": <bool>}, or {"notOpen": true} when no window has the package.
// Before the reply, zero or more progress lines: {"progress": <0...1>} (decision 0049).

/// The `clientInfo` of the MCP client: the request `_meta` in the modern era, else `initialize`.
package struct ClientInfo: Sendable, Equatable {
    package var title: String?
    package var name: String?

    package init(title: String? = nil, name: String? = nil) { (self.title, self.name) = (title, name) }

    /// The `clientInfo` object of a request, or nil when it has none.
    init?(_ object: Any?) {
        guard let object = object as? [String: Any] else { return nil }
        (title, name) = (object["title"] as? String, object["name"] as? String)
    }

    var json: [String: Any] { ["title": title ?? NSNull(), "name": name ?? NSNull()] }
}

/// The answer of the app to one forwarded call.
package enum AgentReply: Sendable, Equatable {
    case result(text: String, isError: Bool)
    /// No window of the app has the package: the bridge runs the call on the files.
    case notOpen

    var line: String {
        switch self {
        case .result(let text, let isError): MCPServer.encode(["text": text, "isError": isError])
        case .notOpen: MCPServer.encode(["notOpen": true])
        }
    }

    init?(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return nil }
        if object["notOpen"] as? Bool == true {
            self = .notOpen
        } else if let text = object["text"] as? String, let isError = object["isError"] as? Bool {
            self = .result(text: text, isError: isError)
        } else {
            return nil
        }
    }
}

/// One line of the app during a call: a progress frame or the reply (decision 0049).
enum AppFrame: Equatable {
    case progress(Double)
    case reply(AgentReply)

    init?(line: Data) {
        let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        if let object, object.count == 1, let fraction = object["progress"] as? Double {
            self = .progress(fraction)
        } else if let reply = AgentReply(line: line) {
            self = .reply(reply)
        } else {
            return nil
        }
    }

    static func progressLine(_ fraction: Double) -> String { MCPServer.encode(["progress": fraction]) }
}

/// The size of one socket read of the listener and the bridge.
let readSize = 64 * 1024

/// The error text of a call whose reply did not come: the app may have run it (C8).
package let lostCallMessage =
    "The connection to Dirigible closed during the call. Read the session before you try again."

/// The lost-call text of `export` and `render`: a job past its last cancel check still writes
/// its file.
func lostFileMessage(_ tool: String) -> String {
    "The connection to Dirigible closed during the call. The \(tool) can still write its file: check the output "
        + "file, and read the session before you try again."
}

/// The socket of the app server: `DIRIGIBLE_MCP_SOCKET` when it is set (the verify copy and the
/// tests), else `mcp.sock` in the Application Support folder of Dirigible.
package func agentSocketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    if let path = environment["DIRIGIBLE_MCP_SOCKET"], !path.isEmpty { return URL(filePath: path) }
    return URL.applicationSupportDirectory.appending(path: "Dirigible/mcp.sock")
}

/// The address of a Unix socket path, or nil when the path does not fit `sun_path` with its NUL.
func unixAddress(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard !bytes.isEmpty, bytes.count < capacity else { return nil }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    }
    return address
}

/// `bind` or `connect` with the address of `path`. Gives the call result, or -1 with `errno`
/// ENAMETOOLONG for a path that does not fit.
func withAddress(_ path: String, _ call: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
    guard var address = unixAddress(path) else {
        errno = ENAMETOOLONG
        return -1
    }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { call($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

/// Writes all of `data` to the socket `fd`. False on an error, for example EPIPE from a peer that
/// closed. `MSG_NOSIGNAL` stops SIGPIPE also when `SO_NOSIGPIPE` failed: `setsockopt` gives EINVAL
/// on an accepted socket whose peer closed before the accept. On a non-blocking fd, a full buffer
/// waits for room until `limit` after the call, so a peer that reads nothing holds the caller
/// for no longer. After false, `errno` gives the cause: ETIMEDOUT for the limit.
func writeAll(_ fd: Int32, _ data: Data, limit: Duration = .seconds(5)) -> Bool {
    let deadline = ContinuousClock.now + limit
    return data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let written = send(fd, buffer.baseAddress! + offset, buffer.count - offset, MSG_NOSIGNAL)
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN {
                let left = ContinuousClock.now.duration(to: deadline)
                guard left > .zero else {
                    errno = ETIMEDOUT
                    return false
                }
                var entry = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                // Round up, so the last wait is not 0 ms.
                _ = poll(&entry, 1, Int32((left / .milliseconds(1)).rounded(.up)))
                continue
            }
            guard written > 0 else { return false }
            offset += written
        }
        return true
    }
}

/// Sets `SO_NOSIGPIPE`, so a write to a peer that closed gives EPIPE and no signal (C16).
func setNoSigPipe(_ fd: Int32) {
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
}
