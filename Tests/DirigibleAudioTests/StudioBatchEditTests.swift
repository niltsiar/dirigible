import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The one edit core of `Studio` (decisions 0002, 0037, and 0046), and the ripple rule of a
/// session value.
@MainActor
struct StudioBatchEditTests {
    /// The refusals of a test body with its own error type.
    enum Refusal: Error, Equatable {
        case studio(StudioError)
        case body
    }

    let package: TakePackage
    /// The pool file of segment `take1-2-1`. No clip uses it.
    let secondFile: FileID
    let agent = AgentName(title: "Test Agent", clientName: nil)

    /// Take 1 has segments `take1-1-1` and `take1-2-1`, both placed. The clip of the second
    /// segment is removed, so a file removal splits the take.
    init() throws {
        package = try TakePackage(tracks: [("t1", .mono), ("t2", .mono)])
        try package.segment(arm: 1, samples: sine(seconds: 1, rate: 48_000))
        try package.segment(arm: 2, samples: sine(seconds: 1, rate: 48_000, frequency: 500))
        var session = try finalizeTake(of: package.read(), in: package.url)
        secondFile = try #require(session.files.first { $0.value.capture == CaptureID("take1-2-1") }?.key)
        try session.removeClips(session.tracks.flatMap(\.clips).filter { $0.file == secondFile }.map(\.id))
        try session.write(to: package.url)
    }

    /// The studio of the package, with a save step that counts its calls.
    func countingStudio() async throws -> (Studio, StepCounter) {
        let saves = StepCounter()
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([])) { session, lock throws(SessionFileError) in
            _ = saves.next()
            return try session.write(under: lock)
        }
        return (studio, saves)
    }

    @Test func canRippleSeesASplitInTheGivenSession() async throws {
        let studio = try await Studio.open(package.url)
        var split = studio.session
        try split.removeFile(secondFile)

        #expect(studio.canRipple, "a wholly placed take blocks a ripple")
        let blocked = !studio.canRipple(split)
        #expect(blocked, "BATCH-S1 the ripple rule read the stored session")
        let allowed = studio.canRipple(studio.session)
        #expect(allowed, "BATCH-S2 the ripple rule blocks a wholly placed take")
        await studio.settle()
    }

    /// A take records, so the ripple rule blocks too: the busy check comes first.
    @Test func aBusyStudioRefusesARippleAsBusy() async throws {
        var session = try package.read()
        try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        try session.write(to: package.url)
        let mic = try #require(
            InputDevice(
                uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
                channelsPerBuffer: [1], latency: 0))
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([mic]))
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        try #require(!studio.canRipple && !studio.isIdle, "the take records")
        let before = studio.session

        #expect(throws: StudioError.busy) {
            try studio.edit(ripple: true) { s throws(SessionError) in try s.renameTrack("t2", to: "Guest") }
        }
        let unchanged = studio.session == before
        #expect(unchanged, "BATCH-S3 a refused ripple changed the session")
        await studio.settle()
    }

    @Test func aThrowOfTheBodyChangesNothing() async throws {
        let (studio, saves) = try await countingStudio()
        try studio.edit(ripple: false) { s throws(SessionError) in try s.renameTrack("t1", to: "Host") }
        await studio.serialized {}
        try #require(saves.calls == 1, "an edit saves once")
        let (before, revision) = (studio.session, studio.sessionRevision)

        #expect(throws: Refusal.body) {
            try studio.edit(agent: agent, refused: Refusal.studio) { s throws(Refusal) in
                do throws(SessionError) { try s.renameTrack("t2", to: "Guest") } catch {
                    throw .studio(.session(error))
                }
                throw .body
            }
        }
        await studio.serialized {}

        let unchanged = studio.session == before
        #expect(unchanged && studio.sessionRevision == revision, "BATCH-S4 a throw of the body changed the session")
        #expect(saves.calls == 1, "BATCH-S5 a throw of the body saved")
        #expect(studio.undoAgent == nil, "BATCH-S6 a throw of the body added an entry")
        try studio.undo()
        #expect(!studio.canUndo, "BATCH-S6 a throw of the body added an entry")
        await studio.settle()
    }

    @Test func manyBodiesAreOneEntryOfTheAgent() async throws {
        let studio = try await Studio.open(package.url)
        let before = studio.session

        try studio.edit(agent: agent, refused: Refusal.studio) { s throws(Refusal) in
            do throws(SessionError) {
                try s.renameTrack("t1", to: "Host")
                try s.renameTrack("t2", to: "Guest")
                try s.addTrack("t3", name: "Music", layout: .mono)
            } catch { throw .studio(.session(error)) }
        }

        #expect(studio.session.tracks.map(\.name) == ["Host", "Guest", "Music"])
        #expect(studio.undoAgent == agent, "BATCH-S7 the entry has no agent")
        try studio.undo()
        let restored = studio.session == before
        #expect(restored, "BATCH-S8 one undo did not give the session before the three changes")
        #expect(!studio.canUndo, "BATCH-S9 three changes in one body made more than one entry")
        await studio.settle()
    }

    @Test func aNoOpBatchAddsNoEntry() async throws {
        let (studio, saves) = try await countingStudio()
        let revision = studio.sessionRevision

        let count = try studio.edit(agent: agent, refused: Refusal.studio) { s throws(Refusal) in s.tracks.count }
        await studio.serialized {}

        #expect(count == 2)
        #expect(!studio.canUndo && studio.sessionRevision == revision, "BATCH-S10 a no-op added an entry")
        #expect(saves.calls == 0, "BATCH-S11 a no-op saved")
        // The same core with a change adds the entry and the save.
        try studio.edit(agent: agent, refused: Refusal.studio) { s throws(Refusal) in
            do throws(SessionError) { try s.renameTrack("t1", to: "Host") } catch { throw .studio(.session(error)) }
        }
        await studio.serialized {}
        #expect(studio.canUndo && studio.sessionRevision == revision + 1 && saves.calls == 1)
        await studio.settle()
    }
}
