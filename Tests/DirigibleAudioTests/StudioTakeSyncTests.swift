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
}
