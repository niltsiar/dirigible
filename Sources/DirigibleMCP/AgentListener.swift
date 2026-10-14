import DirigibleAudio
import DirigibleCore
import Foundation
import os

private let log = Logger(subsystem: "com.delineas.dirigible", category: "agents")

/// One call that a bridge sent, checked on the listener queue (decision 0046).
package struct AgentCall: Sendable {
    /// The package path as the agent gave it, for the error texts.
    let path: String
    /// `packageIdentity` of the path, computed on the listener queue (C6).
    let identity: URL
    let work: ToolWork
    let agent: AgentName
    /// The bridge connection that sent the call. A window grant binds to it (decision 0050).
    let connection: AgentConnection
}

/// The serial of one bridge connection (decisions 0046 and 0050). One counter for the process
/// gives it, so it never repeats in the process, also after a server stop and start.
package struct AgentConnection: Hashable, Sendable {
    package let serial: UInt64

    package init(serial: UInt64) { self.serial = serial }

    private static let counter = OSAllocatedUnfairLock(initialState: UInt64(0))

    static func next() -> AgentConnection {
        AgentConnection(
            serial: counter.withLock {
                $0 += 1
                return $0
            })
    }
}

/// The listener of the app server (decision 0046 Owners). It owns the lock fd, the listener fd,
/// the socket file, and the connections, and is confined to `queue`: each fd is read by a
/// `DispatchSourceRead` there, so no `accept` or `read` runs on the main actor or in a `Task`.
/// The main actor never waits for the queue.
final class AgentListener: @unchecked Sendable {
    /// Answers one call. The job gives its fraction (0...1) to `report`, from any thread.
    typealias Handle = @Sendable (AgentCall, _ report: @escaping @Sendable (Double) -> Void) async -> AgentReply

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
    private let handle: Handle
    private let counted: @Sendable (Int) -> Void
    private let keepAlive: Duration
    private var listenSource: DispatchSourceRead?
    /// Keyed by a serial that never repeats, so a late reply can never find a new connection.
    private var connections: [UInt64: Connection] = [:]
    private var stopped = false

    /// One accepted bridge. It runs one call at a time. Its read source stays on while a call
    /// runs, so a close of the bridge cancels the call (decision 0048).
    private final class Connection {
        let fd: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
        /// The read target, kept for the life of the connection.
        var bytes = [UInt8](repeating: 0, count: readSize)
        /// The running call. A line that comes during the call waits in `buffer`.
        var call: Task<Void, Never>?
        /// The number of the call that has no reply yet, or nil. A progress hop of another call
        /// writes no frame (decision 0049).
        var running: Int?
        var calls = 0
        /// The gate of the frames of the running call.
        var gate = ProgressGate()
        /// The last fraction that went to the bridge, and the timer that sends it again while the
        /// running call reports no new value (decision 0049).
        var last = 0.0
        var keepAlive: DispatchSourceTimer?
        /// The peer shut its write side during a call: the read source is suspended, and the
        /// connection ends after the reply.
        var halfClosed = false
        /// The key of the connection: never the same for two connections.
        let serial: UInt64
        init(fd: Int32, serial: UInt64) { (self.fd, self.serial) = (fd, serial) }
    }

    /// Takes the lock beside `socket`, replaces an old socket file, binds, and listens. It runs
    /// no blocking call. Open after the completion of the stop before it: the old lock is free
    /// then. `handle` answers each call; `counted` gets the number of connections. While a call
    /// runs, a frame goes to its bridge at least once in `keepAlive` while the call is long (decision 0049).
    static func open(
        socket: URL, handle: @escaping Handle, counted: @escaping @Sendable (Int) -> Void,
        keepAlive: Duration = .seconds(10)
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
            socket: socket, lockFD: lockFD, listenFD: listenFD, handle: handle, counted: counted,
            keepAlive: keepAlive)
        listener.queue.async { listener.startAccepting() }
        return .listening(listener)
    }

    private init(
        socket: URL, lockFD: Int32, listenFD: Int32, handle: @escaping Handle,
        counted: @escaping @Sendable (Int) -> Void, keepAlive: Duration
    ) {
        (self.socket, self.lockFD, self.listenFD) = (socket, lockFD, listenFD)
        (self.handle, self.counted, self.keepAlive) = (handle, counted, keepAlive)
    }

    /// Closes the listener, removes the socket file, and then frees the lock, on the queue. Then
    /// `done` runs on the main actor: the next open can take the lock. Each running call is
    /// cancelled, answers, and then its connection closes (decision 0046 Life cycle).
    func stop(then done: @escaping @MainActor @Sendable () -> Void = {}) {
        queue.async { [self] in
            if !stopped {
                stopped = true
                listenSource?.cancel()
                listenSource = nil
                unlink(socket.path)
                close(lockFD)
                for connection in connections.values {
                    if let call = connection.call { call.cancel() } else { end(connection) }
                }
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
            let connection = Connection(fd: fd, serial: AgentConnection.next().serial)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self, unowned connection] in self?.readable(connection) }
            source.setCancelHandler { close(fd) }
            connection.source = source
            connections[connection.serial] = connection
            counted(connections.count)
            source.resume()
        }
    }

    private func readable(_ connection: Connection) {
        let count = read(connection.fd, &connection.bytes, readSize)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        // At EOF during a call, a send of 0 bytes fails only when the peer closed both sides.
        if count == 0, connection.call != nil, send(connection.fd, nil, 0, 0) == 0 {
            connection.halfClosed = true
            connection.source?.suspend()
            return
        }
        guard count > 0, connection.buffer.count + count <= Self.maximumLine else { return end(connection) }
        connection.buffer.append(contentsOf: connection.bytes[..<count])
        nextCall(connection)
    }

    /// Starts the call of the first whole line in the buffer, if there is one.
    private func nextCall(_ connection: Connection) {
        guard connection.call == nil, let newline = connection.buffer.firstIndex(of: UInt8(ascii: "\n")) else { return }
        let line = connection.buffer[connection.buffer.startIndex..<newline]
        connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
        let checked = Self.check(Data(line), connection: AgentConnection(serial: connection.serial))
        connection.calls += 1
        (connection.running, connection.gate, connection.last) = (connection.calls, ProgressGate(), 0)
        let (handle, serial, number) = (handle, connection.serial, connection.calls)
        // A short call sends no frame, so a stalled main actor still gives the lost-call text.
        if case .success(let call) = checked, call.work.isLong {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let interval = DispatchTimeInterval.nanoseconds(Int(keepAlive / .nanoseconds(1)))
            timer.schedule(deadline: .now() + interval, repeating: interval)
            timer.setEventHandler { [weak self] in self?.keptAlive(serial, number) }
            timer.resume()
            connection.keepAlive = timer
        }
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            guard let self else { return }
            queue.async { self.progressed(serial, number, fraction) }
        }
        // The task only waits for the main actor; the reply write runs on the queue.
        connection.call = Task { [self] in
            let reply =
                switch checked {
                case .success(let call): await handle(call, report)
                case .failure(let error): AgentReply.result(text: error.message, isError: true)
                }
            queue.async { self.answered(serial, reply) }
        }
    }

    /// Writes a progress frame of call `number` while that call has no reply, through the gate
    /// of the call (decision 0049). A late hop never reaches the next call.
    private func progressed(_ serial: UInt64, _ number: Int, _ fraction: Double) {
        guard let connection = connections[serial], connection.running == number,
            let value = connection.gate.pass(fraction, at: .now)
        else { return }
        connection.last = value / 100
        frame(connection)
    }

    /// Sends the last value of call `number` again: the bridge limit starts again, and the bridge
    /// sends no notification for a value that did not grow.
    private func keptAlive(_ serial: UInt64, _ number: Int) {
        guard let connection = connections[serial], connection.running == number else { return }
        frame(connection)
    }

    /// A frame that does not arrive whole ends the connection, as a reply does: a part of a frame
    /// would join the next line. A bridge that reads no frame in half the keep-alive time does not
    /// read: the wait ends then, and the queue serves the other connections.
    private func frame(_ connection: Connection) {
        let line = Data((AppFrame.progressLine(connection.last) + "\n").utf8)
        guard writeAll(connection.fd, line, limit: keepAlive / 2) else {
            let code = errno
            log.error("A progress frame to an agent did not arrive whole (errno \(code)). The connection ends.")
            return end(connection)
        }
    }

    /// A reply goes only to the connection that asked, while it is open: a late reply never
    /// answers the call of another connection.
    private func answered(_ serial: UInt64, _ reply: AgentReply) {
        guard let connection = connections[serial] else { return }
        connection.running = nil
        connection.keepAlive?.cancel()
        guard writeAll(connection.fd, Data((reply.line + "\n").utf8)) else {
            let code = errno
            log.error("A reply to an agent did not arrive whole (errno \(code)). The connection ends.")
            return end(connection)
        }
        guard !stopped, !connection.halfClosed else { return end(connection) }
        connection.call = nil
        nextCall(connection)
    }

    private func end(_ connection: Connection) {
        guard connections.removeValue(forKey: connection.serial) != nil else { return }
        connection.call?.cancel()
        connection.keepAlive?.cancel()
        // A suspended source runs its cancel handler only after a resume.
        if connection.halfClosed { connection.source?.resume() }
        connection.source?.cancel()
        connection.source = nil
        counted(connections.count)
    }

    /// Parses a call line and checks its arguments as the file path does, so a bad argument gives
    /// the same text. It computes the package identity here, off the main actor (C6).
    static func check(_ line: Data, connection: AgentConnection) -> Result<AgentCall, ToolError> {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
            let name = object["tool"] as? String, let arguments = object["arguments"] as? [String: Any]
        else { return .failure(ToolError("The call from dirigible mcp is not valid.")) }
        guard let tool = Tool.all.first(where: { $0.name == name }) else {
            return .failure(ToolError("no tool \(name)."))
        }
        // The bridge sends no call of a local tool.
        guard case .package(let params, let make) = tool.body else {
            return .failure(ToolError("The tool \(name) does not run in the app."))
        }
        let client = ClientInfo(object["client"]) ?? ClientInfo()
        do throws(ToolError) {
            let checked = try Arguments(arguments, params: params)
            let work = try make(checked)
            return .success(
                AgentCall(
                    path: checked.path, identity: packageIdentity(checked.package), work: work,
                    agent: AgentName(title: client.title, clientName: client.name), connection: connection))
        } catch {
            return .failure(error)
        }
    }
}
