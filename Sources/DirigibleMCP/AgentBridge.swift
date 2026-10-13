import Foundation

/// The client side of the app socket in `dirigible mcp` (decision 0046 Transport). It is used by
/// one thread: the stdin loop.
package final class AgentBridge {
    /// What became of one forwarded call.
    package enum Outcome: Equatable {
        case reply(AgentReply)
        /// No app listens: the bridge runs the call on the files.
        case noApp
        /// The connection closed, or no reply came in time, after the send: the app may have run
        /// the call, so the bridge never runs it again (C8).
        case lost
    }

    private let socket: URL
    private let timeout: Duration
    private var fd: Int32 = -1
    /// The read target, kept for the life of the bridge.
    private var bytes = [UInt8](repeating: 0, count: readSize)

    /// The longest wait for a reply. A record request and its start fit in it (decision 0048).
    package static let replyLimit = Duration.seconds(30)

    package init(socket: URL = agentSocketPath(), timeout: Duration = replyLimit) {
        (self.socket, self.timeout) = (socket, timeout)
    }

    deinit { disconnect() }

    /// Connects when it has no connection, so the app counts the agent before its first call.
    /// False when no app listens.
    @discardableResult
    package func connect() -> Bool {
        guard fd < 0 else { return true }
        let new = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard new >= 0 else { return false }
        setNoSigPipe(new)
        guard withAddress(socket.path, { Darwin.connect(new, $0, $1) }) == 0 else {
            close(new)
            return false
        }
        fd = new
        return true
    }

    /// Sends one call and waits for its reply. A connection that the app closed before the send
    /// counts as no connection: the bridge connects again once.
    package func call(tool: String, arguments: [String: Any], client: ClientInfo) -> Outcome {
        let line = MCPServer.encode(["tool": tool, "arguments": arguments, "client": client.json]) + "\n"
        if fd >= 0, !isOpen() { disconnect() }
        if fd < 0, !connect() { return .noApp }
        if !writeAll(fd, Data(line.utf8)) {
            disconnect()
            guard connect(), writeAll(fd, Data(line.utf8)) else {
                disconnect()
                return .noApp
            }
        }
        guard let reply = readLine().flatMap(AgentReply.init(line:)) else {
            // A late reply must never answer the next call.
            disconnect()
            return .lost
        }
        return .reply(reply)
    }

    /// The `route` of `MCPServer`: the reply of the app, the lost-call error, or nil to run the
    /// call on the files.
    package func route(tool: String, arguments: [String: Any], client: ClientInfo) -> (text: String, isError: Bool)? {
        switch call(tool: tool, arguments: arguments, client: client) {
        case .reply(.result(let text, let isError)): (text, isError)
        case .lost: (lostCallMessage, true)
        case .reply(.notOpen), .noApp: nil
        }
    }

    /// False when the app closed the connection, or sent bytes that no call asked for.
    private func isOpen() -> Bool {
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&entry, 1, 0) == 0
    }

    /// One reply line, or nil at a close, an error, or the time limit.
    private func readLine() -> Data? {
        var buffer = Data()
        let deadline = ContinuousClock.now + timeout
        while true {
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero else { return nil }
            var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            // Round up, so the last wait is not 0 ms.
            let ready = poll(&entry, 1, Int32((left / .milliseconds(1)).rounded(.up)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let count = read(fd, &bytes, readSize)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: bytes[..<count])
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) { return buffer[buffer.startIndex..<newline] }
        }
    }

    package func disconnect() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }
}
