import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `silences`, `nearest_pause`, and `meter` on a package that the app has open (decision 0062,
/// C11): they read the session of the window through `Studio.readMix`. Track `t1` plays the 3 s
/// tone of `addTone` as clip `c1`, so the session end is frame 144,000.
@MainActor
struct ReadLiveTests {
    let package: LivePackage

    init() throws {
        package = try LivePackage()
        try package.addTone()
    }

    var silences: [String: any Sendable] { ["package": package.path] }

    /// A clip gain of -60 dB that is not saved yet makes the clip a silence for the read.
    @Test func aReadSeesTheUnsavedEdit() async throws {
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let held = try await Self.unsavedEdit(studio)
        defer { held.gate.open() }

        let outcome = await send(folder.socket, "silences", silences)

        #expect(outcome == .reply(.result(text: "0\t144000", isError: false)), "\(outcome)")
        #expect(try Session(contentsOf: package.url).clip("c1")?.clip.gain.dB == 0, "the edit is saved")
        held.gate.open()
        await held.task.value
        await studio.settle()
    }

    @Test func aBusyWindowRefusesTheRead() async throws {
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio, busy: .drag)
        defer { server.stop() }

        let outcome = await send(folder.socket, "meter", ["package": package.path])

        #expect(outcome == .reply(.result(text: AgentBusy.drag.message(package: package.path), isError: true)))
        await studio.settle()
    }

    /// A cancel of the caller stops the read at its next block.
    @Test func aCancelStopsTheRead() async throws {
        let studio = try await package.open()
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        studio.environment.loudnessBlock = { hold.step() }
        let work = try ReadWork.meter(from: 0, to: nil, tracks: [], step: nil).get()
        let read = Task { try await Self.read(work, studio) }
        await until("the read does not hold") { hold.isHeld }

        read.cancel()
        hold.release()

        #expect(try await read.value == .failure(.cancelled))
        await studio.settle()
    }

    /// With the agent server off, the tool reads the saved files with no lock: the unsaved edit
    /// is not in them.
    @Test func withTheServerOffTheToolReadsTheSavedFiles() async throws {
        let studio = try await package.open()
        let held = try await Self.unsavedEdit(studio)
        defer { held.gate.open() }
        let tool = try #require(Tool.all.first { $0.name == "silences" })
        let control = CallControl(token: nil, interval: .zero, send: { _ in }, poll: { _ in false }, step: {})
        let path = package.path

        let answer = await onThread { tool.call(["package": path], control: control) }

        #expect(answer == ("No silence.", false), "\(answer)")
        held.gate.open()
        await held.task.value
        await studio.settle()
    }

    /// A read during a take start gets the busy text, and no scan runs.
    @Test func aReadDuringATakeIsRefused() async throws {
        let studio = try await package.open()
        let blocks = StepCount()
        studio.environment.loudnessBlock = { blocks.step() }
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        studio.isStarting = true

        let outcome = await send(folder.socket, "silences", silences)

        studio.isStarting = false
        #expect(outcome == .reply(.result(text: AgentBusy.task.message(package: package.path), isError: true)))
        #expect(blocks.count == 0, "the read scanned \(blocks.count) blocks")
        await studio.settle()
    }

    /// The end that a take start runs ends a held read, and the read gives the take text.
    @Test func aTakeStartStopsAHeldRead() async throws {
        let studio = try await package.open()
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        studio.environment.loudnessBlock = { hold.step() }
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let (socket, arguments) = (folder.socket, ["package": package.path] as [String: any Sendable])
        let call = Task { await send(socket, "meter", arguments) }
        await until("the read does not hold") { hold.isHeld }

        let end = try #require(studio.exportEnd(), "a take start does not wait for the read")
        await end()
        hold.release()
        let outcome = await call.value

        let text = "Dirigible started a take, so the read stopped."
        #expect(outcome == .reply(.result(text: text, isError: true)), "\(outcome)")
        #expect(studio.exportEnd() == nil, "the read still runs after its end")
        await studio.settle()
    }

    /// A take start after the last block of a read, before its result reaches the main actor,
    /// keeps the complete result: the read never saw the stop.
    @Test func aTakeStartAfterTheLastBlockKeepsTheResult() async throws {
        let studio = try await package.open()

        let result = try await studio.readMix { _, _, _, _ in
            DispatchQueue.main.sync { MainActor.assumeIsolated { studio.endReads(.take) } }
            return 7
        }

        #expect(result == 7)
        await studio.settle()
    }

    /// The close of the window (`settle()`) ends a held read with its text, and `settle()`
    /// returns after the end of the read.
    @Test func theCloseOfTheWindowStopsAHeldRead() async throws {
        let studio = try await package.open()
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        studio.environment.loudnessBlock = { hold.step() }
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let (socket, arguments) = (folder.socket, ["package": package.path] as [String: any Sendable])
        let call = Task { await send(socket, "meter", arguments) }
        await until("the read does not hold") { hold.isHeld }

        let settle = Task { await studio.settle() }
        await until("settle() does not start") { studio.settling }
        hold.release()
        await settle.value

        #expect(studio.readRuns.isEmpty, "a read runs after settle()")
        let outcome = await call.value
        let text = "The session window closed, so the read stopped."
        #expect(outcome == .reply(.result(text: text, isError: true)), "\(outcome)")
    }

    /// The muted track counts for `silences` on the window session too, so its missing file
    /// refuses the read.
    @Test func aMissingFileOnAMutedTrackRefusesTheLiveSilences() async throws {
        let studio = try await package.open()
        try studio.edit(ripple: false) { session throws(SessionError) in try session.setMuted(true, tracks: ["t1"]) }
        try FileManager.default.removeItem(at: package.url.appending(path: "Clips/tone.wav"))
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await send(folder.socket, "silences", silences)

        #expect(outcome == .reply(.result(text: ReadWorkTests.refusal, isError: true)), "\(outcome)")
        await studio.settle()
    }

    /// Sets a clip gain of -60 dB on `c1` while the write turn is held, so the files keep 0 dB
    /// until the gate opens.
    static func unsavedEdit(_ studio: Studio) async throws -> (gate: Gate, task: Task<Void, Never>) {
        let gate = Gate()
        let task = Task { await studio.serialized { await gate.wait() } }
        await until("the write turn is not held") { gate.waiting }
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setGain(Gain(dB: -60)!, clip: "c1")
        }
        return (gate, task)
    }

    /// `work` through `Studio.readMix`, as `liveJob` runs it.
    static func read(_ work: ReadWork, _ studio: Studio) async throws -> Result<ReadOutput, ReadFailure> {
        try await studio.readMix { session, package, progress, isCancelled in
            Result { () throws(ReadFailure) in
                try work.read(session, package: package, progress: progress, isCancelled: isCancelled)
            }
        }
    }
}

/// The count of the blocks that a read scanned.
private final class StepCount: @unchecked Sendable {
    private let lock = NSLock()
    private var steps = 0
    var count: Int { lock.withLock { steps } }
    func step() { lock.withLock { steps += 1 } }
}
