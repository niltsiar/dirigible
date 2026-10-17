import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleMCP

/// Progress and cancel through the bridge (decision 0049, criteria C6 to C8 and C18). Each
/// blocking bridge call runs on its own thread.
@MainActor
struct BridgeProgressTests {
    let rename = ["package": "/x.dirigible", "track": "t1", "name": "A"]

    /// A real listener whose handle is `handle`, on a new socket.
    func listener(_ handle: @escaping AgentListener.Handle) throws -> (AgentListener, SocketFolder) {
        let folder = try SocketFolder()
        guard
            case .listening(let listener) = AgentListener.open(socket: folder.socket, handle: handle, counted: { _ in })
        else { throw POSIXError(.EADDRINUSE) }
        return (listener, folder)
    }

    /// C6: each progress line starts the reply limit again, and the control gets the values. The
    /// fake app has its own threads: the queue of the listeners is shared in the test process, and
    /// a stalled write of another test can hold it for seconds.
    @Test func progressLinesKeepTheCallOpen() async throws {
        let frames = [0.2, 0.4, 0.6, 0.8].map { (0.6, #"{"progress":\#($0)}"#) }
        let app = try FakeApp { _ in .script(frames + [(0.1, #"{"isError":false,"text":"done"}"#)]) }
        let (sent, socket, rename) = (Sent(), app.socket, rename)
        let answer = await onThread {
            var server = MCPServer(route: AgentBridge(socket: socket, timeout: .seconds(1)).route, send: sent.send)
            return server.answer(progressCall("track_rename", rename))
        }
        #expect(toolText(answer) == ("done", false), "the bridge lost a call that sends progress")
        #expect(sent.progress(token: 1) == [20, 40, 60, 80])
    }

    /// C6: a line that is not a frame does not start the limit again.
    @Test func silenceStillLosesTheCall() async throws {
        let app = try FakeApp { _ in .script([(0.6, "junk"), (0.6, #"{"isError":false,"text":"late"}"#)]) }
        let (socket, rename) = (app.socket, rename)
        let answer = await onThread {
            var server = MCPServer(route: AgentBridge(socket: socket, timeout: .seconds(1)).route)
            return server.answer(progressCall("track_rename", rename))
        }
        #expect(toolText(answer) == (generalLimitText(seconds: 1), true), "a junk line kept the call open")
    }

    /// C18: one buffer holds the reads of a call: a frame and the reply in one write give both.
    /// A frame after the reply is lost with the buffer of its call.
    @Test func aFrameAndTheReplyInOneWrite() async throws {
        let app = try FakeApp { call in
            call == 1
                ? .script([
                    (
                        0,
                        #"{"progress":0.5}"# + "\n" + #"{"isError":false,"text":"first"}"# + "\n" + #"{"progress":0.9}"#
                    )
                ])
                : .script([(0, #"{"progress":0.1}"#), (0.2, #"{"isError":false,"text":"second"}"#)])
        }
        let (sent, socket, rename) = (Sent(), app.socket, rename)
        let answers = await onThread {
            var server = MCPServer(route: AgentBridge(socket: socket, timeout: .seconds(1)).route, send: sent.send)
            return [1, 2].map { server.answer(progressCall("track_rename", rename, id: $0, token: $0)) }
        }
        #expect(toolText(answers[0]) == ("first", false), "the reply after a frame in one write was lost")
        #expect(sent.progress(token: 1) == [50])
        #expect(toolText(answers[1]) == ("second", false))
        #expect(sent.progress(token: 2) == [10], "a frame of the first call reached the second call")
    }

    /// C6b: a progress hop that comes after the reply of its call writes no frame, and the
    /// listener writes the frames of the running call.
    @Test func aLateFrameDoesNotReachTheNextCall() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let (listener, folder) = try listener { _, report in
            if calls.withLock({ count in
                count += 1
                return count
            }) == 1 {
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    report(0.9)
                }
                return .result(text: "first", isError: false)
            }
            report(0.05)
            try? await Task.sleep(for: .milliseconds(800))
            return .result(text: "second", isError: false)
        }
        defer { listener.stop() }
        let (sent, socket, rename) = (Sent(), folder.socket, rename)
        let answers = await onThread {
            var server = MCPServer(route: AgentBridge(socket: socket).route, send: sent.send)
            return [1, 2].map { server.answer(progressCall("track_rename", rename, id: $0, token: $0)) }
        }
        #expect(answers.map { toolText($0).text } == ["first", "second"])
        #expect(sent.progress(token: 2) == [5], "a late frame of the first call reached the second call")
    }

    /// C7: a cancel line on stdin closes the socket fully, so the listener cancels the call task.
    /// The cancelled call gets no answer, and the next call connects again.
    @Test func aCancelLineCancelsTheAppCall() async throws {
        let (entered, cancelled) = (OSAllocatedUnfairLock(initialState: 0), OSAllocatedUnfairLock(initialState: false))
        let (listener, folder) = try listener { _, _ in
            guard
                entered.withLock({ count in
                    count += 1
                    return count
                }) == 1
            else { return .result(text: "second", isError: false) }
            try? await Task.sleep(for: .seconds(60))
            cancelled.withLock { $0 = Task.isCancelled }
            return .result(text: "late", isError: false)
        }
        defer { listener.stop() }
        let stdin = try StdinPipe()
        let (socket, fd) = (folder.socket, stdin.readFD)
        stdin.put(progressCall("track_rename", rename, id: 7))
        let answers = Task {
            await onThread { () -> [String?] in
                let input = LineInput(fd: fd)
                var server = MCPServer(
                    route: AgentBridge(socket: socket, input: input).route, pollCancel: input.pollCancel)
                var answers: [String?] = []
                while let line = input.next() { answers.append(server.answer(line)) }
                return answers
            }
        }
        await until("the call did not reach the app") { entered.withLock { $0 } == 1 }
        stdin.put(
            MCPServer.encode(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 7]]))
        await until("the app call was not cancelled") { cancelled.withLock { $0 } }
        stdin.put(progressCall("track_rename", rename, id: 8))
        stdin.closeWrite()
        let all = await answers.value
        // The pipe closes its read end when it goes, so it lives until the server thread ends.
        withExtendedLifetime(stdin) {}
        // Three lines: the call, the cancel, and the next call. Only the next call has an answer.
        let answered = all.compactMap { $0 }
        #expect(all.count == 3 && answered.count == 1, "the cancelled call got an answer: \(all)")
        #expect(toolText(answered.first) == ("second", false))
    }

    /// C8: with stdin at EOF, a wait for the app leaves stdin out of the poll set.
    @Test func aWaitAtEOFDoesNotSpin() async throws {
        let app = try FakeApp { _ in .script([(1.5, #"{"isError":false,"text":"slow"}"#)]) }
        let stdin = try StdinPipe()
        stdin.put(progressCall("track_rename", rename))
        stdin.closeWrite()
        let (socket, fd) = (app.socket, stdin.readFD)
        let (answer, cpu) = await onThread { () -> (String?, UInt64) in
            let input = LineInput(fd: fd)
            var server = MCPServer(route: AgentBridge(socket: socket, input: input).route, pollCancel: input.pollCancel)
            guard let line = input.next() else { return (nil, 0) }
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let answer = server.answer(line)
            return (answer, clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start)
        }
        withExtendedLifetime(stdin) {}
        #expect(toolText(answer) == ("slow", false))
        #expect(cpu < 200_000_000, "the wait at EOF used \(cpu / 1_000_000) ms of CPU")
    }
}

/// A `tools/call` line with `_meta.progressToken`.
func progressCall(_ tool: String, _ arguments: [String: Any], id: Int = 1, token: Int = 1) -> String {
    MCPServer.encode([
        "jsonrpc": "2.0", "id": id, "method": "tools/call",
        "params": ["name": tool, "arguments": arguments, "_meta": ["progressToken": token]],
    ])
}

/// The notification lines that a server sent.
final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func send(_ line: String) { lock.withLock { lines.append(line) } }

    /// The `progress` values of the token, in order.
    func progress(token: Int) -> [Double] {
        lock.withLock { lines }.compactMap { line in
            let params = ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["params"]
            guard let params = params as? [String: Any], params["progressToken"] as? Int == token else { return nil }
            return params["progress"] as? Double
        }
    }
}

/// A pipe for the stdin of a server. `put` writes one line.
final class StdinPipe: @unchecked Sendable {
    let readFD: Int32
    private var writeFD: Int32

    init() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
        (readFD, writeFD) = (fds[0], fds[1])
    }

    func put(_ line: String) {
        // writeAll uses send(2), which a pipe refuses.
        _ = Array((line + "\n").utf8).withUnsafeBytes { write(writeFD, $0.baseAddress, $0.count) }
    }

    func closeWrite() {
        guard writeFD >= 0 else { return }
        close(writeFD)
        writeFD = -1
    }

    deinit {
        closeWrite()
        close(readFD)
    }
}
