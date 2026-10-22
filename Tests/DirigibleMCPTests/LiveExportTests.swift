import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `export` on a package that the app has open: it runs through `Studio.export` (decision 0049,
/// C9). The package has clip `c1` of 3 s, so the export has three chunks.
@MainActor
struct LiveExportTests {
    let package: LivePackage
    var out: URL { package.folder.appending(path: "mix.wav") }
    var arguments: [String: String] { ["package": package.path, "out": out.path] }

    init() throws {
        package = try LivePackage()
        try package.addTone()
    }

    /// The files beside the package.
    func outputs() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.folder.path).filter { $0 != "Show.dirigible" }
    }

    /// Opens the studio with its export held at chunk 2, and starts a server for it.
    func open(_ hold: ChunkHold, dialog: @escaping @MainActor () -> AgentBusy? = { nil }) async throws -> (
        Studio, AgentServer, SocketFolder
    ) {
        let studio = try await package.open()
        studio.environment.exportChunk = { hold.step() }
        let (server, folder) = try liveServer(studio, dialog: dialog)
        return (studio, server, folder)
    }

    /// The bridge gets progress values that grow, before the reply, and the reply is the CLI text.
    @Test func liveExportReportsProgress() async throws {
        let hold = ChunkHold(at: 3)
        defer { hold.release() }
        let (studio, server, folder) = try await open(hold)
        defer { server.stop() }
        let (sent, socket, arguments) = (Sent(), folder.socket, arguments)
        let call = Task {
            await onThread {
                let control = CallControl(token: 1, interval: .zero, send: sent.send, poll: { _ in false }, step: {})
                return AgentBridge(socket: socket, timeout: .seconds(120)).call(
                    tool: "export", arguments: arguments, client: testClient, control: control)
            }
        }
        await until("no progress line before the last chunk") { !sent.progress(token: 1).isEmpty }
        hold.release()
        let outcome = await call.value

        #expect(outcome == .reply(.result(text: "OK", isError: false)))
        let values = sent.progress(token: 1)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 < $1 } && values.allSatisfy { $0 < 100 }, "\(values)")
        #expect(try outputs() == ["mix.wav"])
        await studio.settle()
    }

    /// A cancel line on stdin closes the bridge, the listener cancels the call task, and the
    /// export ends with no file and no answer.
    @Test func aCancelOfTheCallEndsTheExport() async throws {
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        let (studio, server, folder) = try await open(hold)
        defer { server.stop() }
        let stdin = try StdinPipe()
        let (socket, fd) = (folder.socket, stdin.readFD)
        stdin.put(progressCall("export", arguments, id: 7))
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
        await until("the export does not hold") { hold.isHeld && server.connected == 1 }
        stdin.put(
            MCPServer.encode(["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 7]]))
        // The listener cancels the call task before it counts the closed connection.
        await until("the bridge did not close") { server.connected == 0 }
        hold.release()
        await until("the export did not end") { studio.exportProgress == nil }
        stdin.closeWrite()
        let all = await answers.value
        // The pipe closes its read end when it goes, so it lives until the server thread ends.
        withExtendedLifetime(stdin) {}

        #expect(all.count == 2 && all.allSatisfy { $0 == nil }, "the cancelled export got an answer: \(all)")
        #expect(try outputs() == [], "a cancelled export left a file")
        await studio.settle()
    }

    /// Cancel in the export sheet and a take start end the export, and the agent gets the cause.
    @Test(arguments: [
        (ExportStop.user, "The user cancelled the export in Dirigible. No file was written."),
        (.take, "A take started in Dirigible, so the export stopped. No file was written."),
    ])
    func aStopInTheAppGivesItsText(stop: ExportStop, text: String) async throws {
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        let (studio, server, folder) = try await open(hold)
        defer { server.stop() }
        let (socket, arguments) = (folder.socket, arguments)
        let call = Task { await send(socket, "export", arguments) }
        await until("the export does not hold") { hold.isHeld }

        let end = Task {
            if stop == .user { studio.cancelExport() } else { await studio.endExport(.take) }
        }
        // The stop sets its cause and cancels before the held chunk goes on.
        await until("the stop did not start") { studio.exportStop == stop }
        hold.release()
        await end.value
        let outcome = await call.value

        #expect(outcome == .reply(.result(text: text, isError: true)))
        #expect(try outputs() == [], "a stopped export left a file")
        await studio.settle()
    }
}

extension LiveExportTests {
    /// Code gate 1 item 3: a stop of the agent server ends the export with its own text, not the
    /// text of a cancel that the agent did not send.
    @Test func aServerStopGivesItsText() async throws {
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        let (studio, server, folder) = try await open(hold)
        let (socket, arguments) = (folder.socket, arguments)
        let call = Task { await send(socket, "export", arguments) }
        await until("the export does not hold") { hold.isHeld }

        server.stop()
        hold.release()
        let outcome = await call.value

        let text = "Dirigible stopped its agent server, so the export stopped. No file was written."
        #expect(outcome == .reply(.result(text: text, isError: true)))
        #expect(try outputs() == [], "a stopped export left a file")
        await studio.settle()
    }

    /// Code gate 1 item 4: a take in another window stops a render, and the text names the render.
    @Test func aTakeInAnotherWindowGivesTheRenderText() async throws {
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        let (studio, server, folder) = try await open(hold)
        defer { server.stop() }
        let arguments = ["package": package.path, "out": package.folder.appending(path: "mix.caf").path]
        let socket = folder.socket
        let call = Task { await send(socket, "render", arguments) }
        await until("the render does not hold") { hold.isHeld }

        let end = Task { await studio.endExport(.take, yielding: true) }
        await until("the stop did not start") { studio.exportStop == .take }
        hold.release()
        await end.value
        let outcome = await call.value

        let text = "A take started in Dirigible, so the render stopped. No file was written."
        #expect(outcome == .reply(.result(text: text, isError: true)))
        await studio.settle()
    }

    /// Code gate 1 item 4: an export of the window makes an agent export busy, with that cause.
    /// Code gate 2 item 3: the export sheet of the window is a dialog too, as in the app.
    @Test func aWindowExportGivesItsBusyCause() async throws {
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        let (studio, server, folder) = try await open(hold) { .dialog }
        defer { server.stop() }
        let own = package.folder.appending(path: "own.caf")
        let window = Task {
            try await studio.export(ExportSource(range: 0..<144_000)!, .render, to: own, replacing: nil)
        }
        await until("the export of the window does not hold") { hold.isHeld }

        let outcome = await send(folder.socket, "export", arguments)

        let text = "\(package.path) is busy in Dirigible: an export runs in its window. Try again later."
        #expect(outcome == .reply(.result(text: text, isError: true)))
        hold.release()
        _ = try await window.value
        await studio.settle()
    }

    /// Code gate 1 item 4: a take that is not finalized makes an agent export busy, with that cause.
    @Test func aPendingTakeGivesItsBusyCause() async throws {
        try package.addPendingTake()
        let studio = try await package.open(pending: true)
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await send(folder.socket, "export", arguments)

        let text = "\(package.path) is busy in Dirigible: a take is not finalized. Try again later."
        #expect(outcome == .reply(.result(text: text, isError: true)))
        await studio.settle()
    }

    /// Code gate 1 item 1: a window that shows a dialog refuses an agent export with no file.
    @Test func aDialogRefusesTheExport() async throws {
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio) { .dialog }
        defer { server.stop() }

        let outcome = await send(folder.socket, "export", arguments)

        let text =
            "\(package.path) is busy in Dirigible: its window shows an alert, a sheet, or a panel. "
            + "Ask the user to finish or close it in Dirigible, then try again."
        #expect(outcome == .reply(.result(text: text, isError: true)))
        #expect(try outputs() == [], "the export ran")
        await studio.settle()
    }

    /// Code gate 2 item 2: a dialog that opens during the media check refuses the export.
    @Test func aDialogDuringTheMediaCheckRefusesTheExport() async throws {
        let studio = try await package.open()
        let shown = OSAllocatedUnfairLock(initialState: false)
        studio.environment.beforeMediaCheck = { shown.withLock { $0 = true } }
        let (server, folder) = try liveServer(studio) { shown.withLock { $0 } ? .dialog : nil }
        defer { server.stop() }

        let outcome = await send(folder.socket, "export", arguments)

        let text =
            "\(package.path) is busy in Dirigible: its window shows an alert, a sheet, or a panel. "
            + "Ask the user to finish or close it in Dirigible, then try again."
        #expect(outcome == .reply(.result(text: text, isError: true)))
        #expect(try outputs() == [], "the export ran")
        await studio.settle()
    }

    /// Code gate 2 item 4: a render in the app reads no media state. `ExportWork.checkFiles` has
    /// the same rule on the files; no test can fail its media check alone.
    @Test func aRenderRunsNoMediaCheck() async throws {
        let studio = try await package.open()
        let checks = OSAllocatedUnfairLock(initialState: 0)
        studio.environment.beforeMediaCheck = { checks.withLock { $0 += 1 } }
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let caf = package.folder.appending(path: "mix.caf")

        let outcome = await send(folder.socket, "render", ["package": package.path, "out": caf.path])

        #expect(outcome == .reply(.result(text: "OK", isError: false)))
        #expect(checks.withLock { $0 } == 0, "the render ran a media check")
        await studio.settle()
    }

    /// A live `chapters_export` writes the chapters of the
    /// session of the window. The write turn is held, so the files do not have the chapter. A
    /// dialog refuses the call first, as `export`: only `liveJob` reads the dialog.
    @Test func aLiveChaptersExportReadsTheOpenSession() async throws {
        let studio = try await package.open()
        let shown = OSAllocatedUnfairLock(initialState: true)
        let (server, folder) = try liveServer(studio, dialog: { shown.withLock { $0 } ? .dialog : nil })
        defer { server.stop() }
        let gate = Gate()
        defer { gate.open() }
        let held = Task { await studio.serialized { await gate.wait() } }
        await until("the write turn is not held") { gate.waiting }
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMarker(Marker(id: "a", name: "Intro", position: 0, kind: .chapter))
        }
        let (text, json) = (package.folder.appending(path: "show.txt"), package.folder.appending(path: "show.json"))

        let refused = await send(folder.socket, "chapters_export", ["package": package.path, "out": text.path])
        shown.withLock { $0 = false }
        let written = await send(folder.socket, "chapters_export", ["package": package.path, "out": text.path])
        let both = await send(folder.socket, "chapters_export", ["package": package.path, "out": json.path])

        #expect(refused == .reply(.result(text: AgentBusy.dialog.message(package: package.path), isError: true)))
        #expect([written, both] == Array(repeating: .reply(.result(text: "OK", isError: false)), count: 2))
        #expect(try String(contentsOf: text, encoding: .utf8) == "00:00:00 Intro\n")
        let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        #expect((file["chapters"] as? [[String: Any]])?.compactMap { $0["title"] as? String } == ["Intro"])
        #expect(
            try Session(contentsOf: package.url).markers.isEmpty, "the autosave waits, so the files have no chapter")
        gate.open()
        await held.value
        await studio.settle()
    }
}

/// Holds the export of a studio once, at chunk `at`, until `release`.
final class ChunkHold: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let at: Int
    private var calls = 0
    private var held = false

    init(at: Int) { self.at = at }

    var isHeld: Bool { lock.withLock { held } }

    func step() {
        let hold = lock.withLock {
            calls += 1
            held = held || calls == at
            return calls == at
        }
        if hold { semaphore.wait() }
    }

    /// A second release leaves the semaphore at 1, which no later step reads.
    func release() { semaphore.signal() }
}
