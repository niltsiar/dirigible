import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The job rules of Level Over Time (C6, C10 to C12b, C32): fixture A with a passage at -10 dB.
@MainActor
struct StudioRideJobTests {
    static let speech = rideSpeech(seconds: 40) { (12..<28).contains($0) ? -10 : 0 }

    /// C12b: a second ride with no change between writes equal lists, so no save and no undo
    /// entry; one Undo then gives the clip with no ride.
    @Test func secondRideChangesNothing() async throws {
        let fixture = try await RideFixture(Self.speech)
        try await fixture.ride()
        let (first, bytes) = (try fixture.clip().ride, try fixture.sessionBytes())
        let report = try await fixture.ride()
        let (second, saved) = (try fixture.clip().ride, try fixture.sessionBytes())
        #expect(second == first && report.leveled == ["c1"], "\(report)")
        #expect(saved == bytes, "a second ride saved")
        try fixture.studio.undo()
        let undone = try fixture.clip().ride
        #expect(undone.isEmpty && !fixture.studio.canUndo, "a second ride made an undo entry")
    }

    /// C12b: a manual lift between two rides gives a new layer from the new envelope.
    @Test func rideAfterAManualPointMeasuresIt() async throws {
        let fixture = try await RideFixture(Self.speech)
        try await fixture.ride()
        let first = try fixture.clip().ride
        _ = try fixture.studio.edit(ripple: false) { session throws(SessionError) in
            try session.changeGain(by: Gain(dB: 6)!, in: 576_000..<1_344_000, on: ["t1"], ramp: session.gainRamp)
        }
        try await fixture.ride()
        let second = try fixture.clip().ride
        #expect(second != first, "the ride did not read the new envelope")
        let (old, new) = (first.gain(at: stepCentre(200)), second.gain(at: stepCentre(200)))
        #expect(new < old - 2, "lifted twice: ride at 20 s \(old) before the lift, \(new) after it")
    }

    /// C10: a silent clip gets no ride (its old ride goes) and is listed as unmeasured.
    @Test func silentClipGetsNoRide() async throws {
        let fixture = try await RideFixture(
            Self.speech,
            files: { package in
                try package.addFile("f2", channels: [[Float](repeating: 0, count: 480_000)])
                try package.addTrack("t2", clip: "c2", file: "f2", start: 0, offset: 0, length: 480_000)
                try package.session.setRides(["c2": GainEnvelope([.init(frame: 2_400, gain: Gain(dB: 3)!)])!])
            })
        let studio = fixture.studio
        let report = try await studio.levelOverTime(["c1", "c2"], agent: nil)
        #expect(report.leveled == ["c1"] && report.unmeasured == ["c2"], "\(report)")
        #expect(try #require(studio.session.clip("c2")).clip.ride.isEmpty, "a ride point on the silent clip")
    }

    /// C10: a ride of silent clips with no ride saves nothing and records no undo entry.
    @Test func allSilentMakesNoUndo() async throws {
        let fixture = try await RideFixture([Float](repeating: 0, count: 480_000))
        let bytes = try fixture.sessionBytes()
        let report = try await fixture.ride()
        #expect(report.unmeasured == ["c1"] && report.leveled.isEmpty && report.largestGain == nil, "\(report)")
        let saved = try fixture.sessionBytes()
        #expect(!fixture.studio.canUndo && saved == bytes, "a silent ride changed the session")
    }

    /// C11: a source that ends early stops the ride with the fault of its file; nothing changes.
    @Test func readFaultWritesNothing() async throws {
        let fixture = try await RideFixture(Self.speech)
        let frames = try fixture.package.truncate("f1", toBytes: 1_000_000)
        try await expectNoChange(fixture, .rideFault("f1", .short(Frames(frames))))
    }

    /// C11: the banner Cancel during the read throws `.rideCancelled`; nothing changes.
    @Test func cancelWritesNothing() async throws {
        let fixture = try await RideFixture(Self.speech)
        let gate = AsyncGate()
        fixture.studio.environment.beforeFinalize = { await gate.wait() }
        let before = (fixture.studio.session, try fixture.sessionBytes())
        let riding = Task { try await fixture.ride() }
        await gate.entered()
        #expect(fixture.studio.transport == .riding, "ride hold: \(fixture.studio.transport)")
        fixture.studio.cancelReadJob()
        gate.open()
        let result = await riding.result
        #expect(throws: StudioError.rideCancelled) { try result.get() }
        #expect(fixture.studio.session == before.0 && !fixture.studio.canUndo, "a cancelled ride changed the session")
        #expect(try fixture.sessionBytes() == before.1, "a cancelled ride saved")
    }

    /// C6: a NaN in the source stops the ride with `.unreadable`; nothing changes.
    @Test func nonFiniteSourceWritesNothing() async throws {
        var samples = Self.speech
        samples[100_000] = .nan
        let fixture = try await RideFixture(samples, float: true)
        try await expectNoChange(fixture, .rideFault("f1", .unreadable))
    }

    /// C12: a ride holds the `.riding` transport and refuses an edit; then it is one undo entry:
    /// Undo gives the clip with no ride and Redo the ride, with no read.
    @Test func rideIsOneUndoEntry() async throws {
        let fixture = try await RideFixture(Self.speech)
        let gate = AsyncGate()
        fixture.studio.environment.beforeFinalize = { await gate.wait() }
        let riding = Task { try await fixture.ride() }
        await gate.entered()
        #expect(throws: StudioError.busy) { try fixture.studio.edit(ripple: false) { _ throws(SessionError) in } }
        gate.open()
        _ = try await riding.value
        let ridden = try fixture.clip().ride
        #expect(!ridden.isEmpty && fixture.studio.transport == .idle)
        try fixture.studio.undo()
        let undone = try fixture.clip().ride
        #expect(undone.isEmpty && !fixture.studio.canUndo, "the ride is more than one entry")
        try fixture.studio.redo()
        #expect(try fixture.clip().ride == ridden, "Redo did not give the ride")
    }

    /// C12: a ride during a take throws `busy`, changes nothing, and the take goes on.
    @Test func busyDuringTake() async throws {
        let fixture = try await RideFixture(Self.speech) { session in
            try session.setRoute(Route.device(uid: "mic", channels: .mono(1)), track: "t1")
        }
        let studio = fixture.studio
        studio.environment = .test(TestHAL([StopLevelTests.mic]))
        _ = try await studio.startTake(
            armed: ["t1"], devices: [StopLevelTests.mic], playhead: 0, hostTimeNanos: takeStart)
        let before = studio.session
        await #expect(throws: StudioError.busy) { try await fixture.ride() }
        #expect(studio.session == before && studio.transport == .recording(take: 1), "\(studio.transport)")
        try await studio.stopRecording()
    }

    /// C32: Remove Level Over Time on whole clips is one undo entry with no read; a remove with no
    /// ride changes nothing and records no entry.
    @Test func removeIsOneUndoEntry() async throws {
        let ride = GainEnvelope([.init(frame: 24_000, gain: Gain(dB: 4)!), .init(frame: 96_000, gain: Gain(dB: -2)!)])!
        let fixture = try await RideFixture(Self.speech) { try $0.setRides(["c1": ride]) }
        #expect(try fixture.studio.removeLevelOverTime(["c1"], in: nil, agent: nil) == ["c1"])
        #expect(try fixture.clip().ride.isEmpty)
        #expect(try fixture.studio.removeLevelOverTime(["c1"], in: nil, agent: nil).isEmpty)
        try fixture.studio.undo()
        let undone = try fixture.clip().ride
        #expect(undone == ride && !fixture.studio.canUndo, "the remove is not one entry")
    }

    /// C32: Remove Level Over Time on a range is one undo entry: 0 dB in the range, and one Undo
    /// gives the old list.
    @Test func removeOnARangeIsOneUndoEntry() async throws {
        let ride = GainEnvelope([.init(frame: 24_000, gain: Gain(dB: 4)!), .init(frame: 960_000, gain: Gain(dB: -2)!)])!
        let fixture = try await RideFixture(Self.speech) { try $0.setRides(["c1": ride]) }
        #expect(try fixture.studio.removeLevelOverTime(["c1"], in: 240_000..<480_000, agent: nil) == ["c1"])
        let removed = try fixture.clip().ride
        #expect([240_000, 360_000, 479_999].allSatisfy { removed.gain(at: Frames($0)) == 0 }, "\(removed)")
        try fixture.studio.undo()
        let undone = try fixture.clip().ride
        #expect(undone == ride && !fixture.studio.canUndo, "the remove is not one entry")
    }

    func expectNoChange(_ fixture: RideFixture, _ error: StudioError) async throws {
        let before = (fixture.studio.session, try fixture.sessionBytes())
        await #expect(throws: error) { try await fixture.ride() }
        #expect(fixture.studio.session == before.0 && !fixture.studio.canUndo, "a failed ride changed the session")
        #expect(try fixture.sessionBytes() == before.1, "a failed ride saved")
        #expect(fixture.studio.transport == .idle)
    }
}
