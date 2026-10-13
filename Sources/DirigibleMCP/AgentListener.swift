import DirigibleAudio
import DirigibleCore
import Foundation

/// One call that a bridge sent, checked on the listener queue (decision 0046).
package struct AgentCall: Sendable {
    /// The package path as the agent gave it, for the error texts.
    let path: String
    /// `packageIdentity` of the path, computed on the listener queue (C6).
    let identity: URL
    let work: ToolWork
    let agent: AgentName
}

/// The listener of the app server (decision 0046 Owners). It owns the lock fd, the listener fd,
/// the socket file, and the connections, and is confined to `queue`: each fd is read by a
/// `DispatchSourceRead` there, so no `accept` or `read` runs on the main actor or in a `Task`.
/// The main actor never waits for the queue.
final class AgentListener: @unchecked Sendable {
    enum Opening {
        case listening(AgentListener)
        /// Another process holds the lock: it serves the agents (C9).
        case servedElsewhere
        case failed
    }

    /// The longest call line. A longer line closes its connection.
    static let maximumLine = 4 << 20

    private static let queue = DispatchQueue(label: "Dirigible.AgentListener")
    private let queue = AgentListener.queue
    private let socket: URL
    private let lockFD: Int32
    private let listenFD: Int32
    private let handle: @Sendable (AgentCall) async -> AgentReply
    private let counted: @Sendable (Int) -> Void
    private var listenSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var stopped = false

    /// One accepted bridge. It runs one call at a time: its read source is suspended while its
    /// call runs.
    private final class Connection {
        let fd: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
        /// The read target, kept for the life of the connection.
        var bytes = [UInt8](repeating: 0, count: readSize)
        /// True while a call runs: the read source is suspended then.
        var running = false
        init(fd: Int32) { self.fd = fd }
    }

    /// Takes the lock beside `socket`, replaces an old socket file, binds, and listens. It runs
    /// no blocking call. Open after the completion of the stop before it: the old lock is free
    /// then. `handle` answers each call; `counted` gets the number of connections.
    static func open(
        socket: URL, handle: @escaping @Sendable (AgentCall) async -> AgentReply,
        counted: @escaping @Sendable (Int) -> Void
    ) -> Opening {
        let folder = socket.deletingLastPathComponent().path
        guard unixAddress(socket.path) != nil else { return .failed }
        if mkdir(folder, 0o700) != 0, errno != EEXIST { return .failed }
        let lockFD = Darwin.open(socket.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { return .failed }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            let held = errno == EWOULDBLOCK
            close(lockFD)
            return held ? .servedElsewhere : .failed
        }
        // With the lock held, a socket file is from a process that ended (U1c).
        unlink(socket.path)
        let listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            close(lockFD)
            return .failed
        }
        // The mode is set before `listen`, so no client can connect before it is 0600. No umask
        // call: the umask is of the whole process, so it would change the files of a take.
        let bound = withAddress(socket.path) { bind(listenFD, $0, $1) }
        guard bound == 0, chmod(socket.path, 0o600) == 0, listen(listenFD, 8) == 0,
            fcntl(listenFD, F_SETFL, O_NONBLOCK) == 0
        else {
            close(listenFD)
            if bound == 0 { unlink(socket.path) }
            close(lockFD)
            return .failed
        }
        let listener = AgentListener(
            socket: socket, lockFD: lockFD, listenFD: listenFD, handle: handle, counted: counted)
        listener.queue.async { listener.startAccepting() }
        return .listening(listener)
    }

    private init(
        socket: URL, lockFD: Int32, listenFD: Int32, handle: @escaping @Sendable (AgentCall) async -> AgentReply,
        counted: @escaping @Sendable (Int) -> Void
    ) {
        (self.socket, self.lockFD, self.listenFD) = (socket, lockFD, listenFD)
        (self.handle, self.counted) = (handle, counted)
    }

    /// Closes the listener, removes the socket file, and then frees the lock, on the queue. Then
    /// `done` runs on the main actor: the next open can take the lock. Each connection answers
    /// its running call, then closes (decision 0046 Life cycle).
    func stop(then done: @escaping @MainActor @Sendable () -> Void = {}) {
        queue.async { [self] in
            if !stopped {
                stopped = true
                listenSource?.cancel()
                listenSource = nil
                unlink(socket.path)
                close(lockFD)
                for connection in connections.values where !connection.running { end(connection) }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }

    /// The fds of the open connections, for the tests.
    var connectionFDs: [Int32] { queue.sync { connections.values.map(\.fd) } }

    private func startAccepting() {
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        let fd = listenFD
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.setCancelHandler { close(fd) }
        listenSource = source
        source.resume()
    }

    private func acceptAll() {
        while !stopped {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            // The fd takes O_NONBLOCK from the listener, so no read blocks the queue.
            setNoSigPipe(fd)
            let connection = Connection(fd: fd)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self, unowned connection] in self?.readable(connection) }
            source.setCancelHandler { close(fd) }
            connection.source = source
            connections[ObjectIdentifier(connection)] = connection
            counted(connections.count)
            source.resume()
        }
    }

    private func readable(_ connection: Connection) {
        let count = read(connection.fd, &connection.bytes, readSize)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0, connection.buffer.count + count <= Self.maximumLine else { return end(connection) }
        connection.buffer.append(contentsOf: connection.bytes[..<count])
        nextCall(connection)
    }

    /// Starts the call of the first whole line in the buffer, if there is one.
    private func nextCall(_ connection: Connection) {
        guard !connection.running, let newline = connection.buffer.firstIndex(of: UInt8(ascii: "\n")) else { return }
        let line = connection.buffer[connection.buffer.startIndex..<newline]
        connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
        connection.running = true
        connection.source?.suspend()
        let checked = Self.check(Data(line))
        let (handle, key) = (handle, ObjectIdentifier(connection))
        // The task only waits for the main actor; the reply write runs on the queue. The task
        // keeps the listener until the reply, also after a stop: a freed suspended source traps.
        Task { [self] in
            let reply =
                switch checked {
                case .success(let call): await handle(call)
                case .failure(let error): AgentReply.result(text: error.message, isError: true)
                }
            queue.async { self.answered(key, reply) }
        }
    }

    private func answered(_ key: ObjectIdentifier, _ reply: AgentReply) {
        guard let connection = connections[key] else { return }
        let sent = writeAll(connection.fd, Data((reply.line + "\n").utf8))
        guard sent, !stopped else { return end(connection) }
        connection.running = false
        connection.source?.resume()
        nextCall(connection)
    }

    private func end(_ connection: Connection) {
        guard connections.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        // A suspended source runs its cancel handler only after a resume.
        if connection.running { connection.source?.resume() }
        connection.source?.cancel()
        connection.source = nil
        counted(connections.count)
    }

    /// Parses a call line and checks its arguments as the file path does, so a bad argument gives
    /// the same text. It computes the package identity here, off the main actor (C6).
    static func check(_ line: Data) -> Result<AgentCall, ToolError> {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            let name = object["tool"] as? String, let arguments = object["arguments"] as? [String: Any]
        else { return .failure(ToolError("The call from dirigible mcp is not valid.")) }
        guard let tool = Tool.all.first(where: { $0.name == name }) else {
            return .failure(ToolError("no tool \(name)."))
        }
        let client = ClientInfo(object["client"]) ?? ClientInfo()
        do throws(ToolError) {
            let checked = try Arguments(arguments, params: tool.params)
            let work = try tool.make(checked)
            return .success(
                AgentCall(
                    path: checked.path, identity: packageIdentity(checked.package), work: work,
                    agent: AgentName(title: client.title, clientName: client.name)))
        } catch {
            return .failure(error)
        }
    }
}
