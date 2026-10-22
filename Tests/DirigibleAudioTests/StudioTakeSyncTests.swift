import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// The take sync state of an open window (decision 0061, C2).
@MainActor
struct StudioTakeSyncTests {
    static let fault = FinalizeError.readFailed(file: "Capture/take9.anchor", errno: EACCES)

    /// Writes the anchor of take 9 with the real writer and makes it unreadable (mode 000).
    static func unreadableAnchor(in package: TakePackage) throws {
        try TakeAnchor.write(
            Recording(take: 9, playheadFrame: 0, takeStartHostTimeNanos: takeStart, armedTracks: ["t1"]),
            in: package.url)
        chmod(package.capture.appending(path: "take9.anchor").path, 0o000)
    }

    static func clips(_ session: Session) -> [ClipID] { session.tracks.flatMap(\.clips).map(\.id) }

    /// An anchor fault never stops or rolls back an open, a take end, or a placement: each one
    /// succeeds, `session.xml` and the studio keep the new take, and the studio names the fault.
    @Test func anAnchorFaultKeepsTheTake() async throws {
        // The open, whose recovery ends the pending take.
        let opened = try TakePackage()
        try opened.segment(samples: sine(seconds: 1, rate: 48_000))
        try Self.unreadableAnchor(in: opened)
        let first = try await Studio.open(opened.url)
        #expect(first.pendingTake == nil && first.takeError == nil)
        #expect(Self.clips(first.session) == ["take1-1-1"])
        #expect(Self.clips(try opened.read()) == ["take1-1-1"])
        #expect(first.takeSyncFault == Self.fault, "open: \(String(describing: first.takeSyncFault))")
        await first.settle()

        // The take end of a retry, after an open whose finalize failed on a read-only `Clips/`.
        let retried = try TakePackage()
        try retried.segment(samples: sine(seconds: 1, rate: 48_000))
        let clipsFolder = retried.url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clipsFolder, withIntermediateDirectories: true)
        chmod(clipsFolder.path, 0o500)
        let second = try await Studio.open(retried.url)
        chmod(clipsFolder.path, 0o755)
        try #require(second.pendingTake?.take == 1)
        try Self.unreadableAnchor(in: retried)
        #expect(second.takeSyncFault == nil, "the fault is there before the take end")
        try await second.retryFinalize()
        #expect(second.pendingTake == nil && second.takeError == nil)
        #expect(Self.clips(second.session) == ["take1-1-1"])
        #expect(Self.clips(try retried.read()) == ["take1-1-1"])
        #expect(second.takeSyncFault == Self.fault, "take end: \(String(describing: second.takeSyncFault))")
        await second.settle()

        // The placement of a segment that the take end left out.
        let placed = try TakePackage(tracks: [("t1", .mono), ("t2", .mono)])
        try placed.segment(arm: 1, samples: sine(seconds: 1, rate: 48_000))
        try finalizeTake(of: placed.read(), in: placed.url).write(to: placed.url)
        try placed.segment(arm: 2, samples: sine(seconds: 1, rate: 48_000))
        let third = try await Studio.open(placed.url)
        try Self.unreadableAnchor(in: placed)
        #expect(third.takeSyncFault == nil, "the fault is there before the placement")
        let clip = try await third.place(SegmentName(take: 1, arm: 2, segment: 1))
        #expect(clip == "take1-2-1")
        #expect(Self.clips(third.session) == ["take1-1-1", "take1-2-1"])
        #expect(Self.clips(try placed.read()) == ["take1-1-1", "take1-2-1"])
        #expect(third.takeSyncFault == Self.fault, "placement: \(String(describing: third.takeSyncFault))")
        await third.settle()
    }

    /// C8: an agent edit, an undo, and a redo, each followed by 200 playhead moves and 5 reads,
    /// make 3 maps. Each change has the revision and the agent of its revision: none for the undo.
    @Test func theSyncIsMadeOncePerRevision() async throws {
        let package = try TakePackage()
        try package.segment(samples: sine(seconds: 1, rate: 48_000))
        let studio = try await Studio.open(package.url)
        try #require(studio.pendingTake == nil && studio.takeError == nil)
        let agent = AgentName(title: "Test Agent", clientName: nil)
        let (made, revision) = (studio.takeSyncState.made, studio.sessionRevision)
        var changes: [TakeSyncChange] = []
        func moveAndRead() async {
            for frame in 0..<200 { await studio.perform(.seek(.frame(Frames(frame * 100)))) }
            for _ in 0..<5 { _ = (studio.takeMap, studio.takeSyncFault, studio.takeSyncChange) }
            changes.append(studio.takeSyncChange)
        }

        try studio.edit(ripple: true, agent: agent) { session throws(SessionError) in
            try session.rippleInsert(1000, at: 0, on: session.tracks.map(\.id))
        }
        await moveAndRead()
        try studio.undo()
        await moveAndRead()
        try studio.redo()
        await moveAndRead()

        #expect(studio.takeSyncState.made - made == 3)
        #expect(changes.map(\.revision) == [revision + 1, revision + 2, revision + 3])
        #expect(changes.map(\.agent) == [agent, nil, agent])
        let insert = try #require(changes[0].changes.first)
        #expect(changes[0].changes.count == 1 && insert.take == 1)
        if case .inSync(let old) = insert.old, case .inSync(let new) = insert.new {
            #expect(new - old == 1000)
        } else {
            Issue.record("the insert at 0 is not an offset change: \(insert)")
        }
        #expect(changes[1].changes.map { [$0.old, $0.new] } == [[insert.new, insert.old]])
        await studio.settle()
    }
}
