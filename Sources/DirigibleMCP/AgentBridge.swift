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
    /// The stdin of `dirigible mcp`. During a call the bridge reads it too (decisions 0048 and
    /// 0049).
    private let input: LineInput?
    private var fd: Int32 = -1
    /// The read target, kept for the life of the bridge.
    private var bytes = [UInt8](repeating: 0, count: readSize)

    /// The longest wait with no line from the app. A record request and its start fit in it
    /// (decision 0048), and each progress line starts it again (decision 0049).
    package static let replyLimit = Duration.seconds(30)

    package init(socket: URL = agentSocketPath(), timeout: Duration = replyLimit, input: LineInput? = nil) {
        (self.socket, self.timeout, self.input) = (socket, timeout, input)
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
    /// counts as no connection: the bridge connects again once. With `control`, the progress
    /// lines of the app go to it, and the wait reads stdin for a cancel (decision 0049).
    package func call(tool: String, arguments: [String: Any], client: ClientInfo, control: CallControl? = nil)
        -> Outcome
    {
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
        guard let reply = reply(control: control, record: tool == "record") else {
            // A late reply must never answer the next call. A full close also cancels the call
            // in the app: the listener keeps a half-close (decision 0049).
            disconnect()
            return .lost
        }
        return .reply(reply)
    }

    /// The `route` of `MCPServer`: the reply of the app, the lost-call error, or nil to run the
    /// call on the files.
    package func route(tool: String, arguments: [String: Any], client: ClientInfo, control: CallControl) -> (
        text: String, isError: Bool
    )? {
        switch call(tool: tool, arguments: arguments, client: client, control: control) {
        case .reply(.result(let text, let isError)): (text, isError)
        case .lost: (["export", "render"].contains(tool) ? lostFileMessage(tool) : lostCallMessage, true)
        case .reply(.notOpen), .noApp: nil
        }
    }

    /// False when the app closed the connection, or sent bytes that no call asked for.
    private func isOpen() -> Bool {
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&entry, 1, 0) == 0
    }

    /// The reply of the app, or nil at a close, an error, the time limit, a cancel on stdin, or
    /// the end of stdin during a `record` call. One buffer holds the reads of the whole call, and
    /// each whole line in it is handled before the next poll. Each progress line goes to
    /// `control` and starts the limit again; another line that is not a reply changes nothing.
    /// After EOF, stdin is out of the poll set, so the wait does not spin (decision 0049).
    private func reply(control: CallControl?, record: Bool) -> AgentReply? {
        let stdin = control == nil ? nil : input
        var buffer = Data()
        var deadline = ContinuousClock.now + timeout
        while true {
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                switch AppFrame(line: line) {
                case .progress(let fraction):
                    control?.report(fraction)
                    deadline = ContinuousClock.now + timeout
                case .reply(let reply): return reply
                case nil: continue
                }
            }
            if let stdin {
                if record, stdin.ended { return nil }
                if control?.isCancelled() == true { return nil }
            }
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero else { return nil }
            var entries = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
            if let stdin, !stdin.ended { entries.append(pollfd(fd: stdin.fd, events: Int16(POLLIN), revents: 0)) }
            // Round up, so the last wait is not 0 ms.
            let ready = poll(&entries, nfds_t(entries.count), Int32((left / .milliseconds(1)).rounded(.up)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            if entries.count > 1, entries[1].revents != 0 { stdin?.fill() }
            guard entries[0].revents != 0 else { continue }
            let count = read(fd, &bytes, readSize)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: bytes[..<count])
        }
    }

    package func disconnect() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }
}
