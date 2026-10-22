import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// C17: the duck of Tools > Duck Music Under Speech... through `Studio.duck` (decision 0060). Track
/// t1 (dialogue) has c1: 3 s of a -20 dBFS sine, or silence. Track t2 (music) has c2: 3 s of a
/// -20 dBFS sine, with one gain point of -6 dB at frame 72 000 before the duck.
@MainActor
struct StudioDuckTests {
    let package: MixPackage
    let shape = DuckShape.defaults(sampleRate: 48_000)

    init(speech dBFS: Double = -20) throws {
        package = try MixPackage()
        try package.addFile("f1", channels: tone([(3, dBFS)], layout: .mono))
        try package.addFile("f2", channels: tone([(3, -20)], layout: .mono))
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 144_000)
        try package.addTrack("t2", clip: "c2", file: "f2", start: 0, offset: 0, length: 144_000)
        try package.session.setRole(.dialogue, tracks: ["t1"])
        try package.session.setRole(.music, tracks: ["t2"])
        try package.session.setEnvelope([72_000: Gain(dB: -6)!], clip: "c2")
        try package.session.write(to: package.url)
    }

    func duck(_ studio: Studio) async throws(StudioError) -> DuckResult {
        try await studio.duck(speech: ["t1"], music: ["t2"], range: nil, shape: shape)
    }

    func sessionBytes() throws -> Data { try Data(contentsOf: package.url.appending(path: "session.xml")) }

    /// The duck holds the `.ducking` transport and refuses an edit; then the music is at the depth
    /// under the speech, and one Undo gives back the point of before.
    @Test func aDuckIsOneUndoStep() async throws {
        let studio = try await Studio.open(package.url)
        let before = studio.session
        let gate = AsyncGate()
        studio.environment.beforeFinalize = { await gate.wait() }

        let ducking = Task { try await duck(studio) }
        await gate.entered()
        #expect(studio.transport == .ducking, "duck hold: \(studio.transport)")
        #expect(throws: StudioError.busy) { try studio.edit(ripple: false) { _ throws(SessionError) in } }
        gate.open()
        let result = try await ducking.value

        #expect(studio.transport == .idle, "after the duck: \(studio.transport)")
        #expect(result.ducked == ["c2"], "\(result)")
        #expect(studio.session.clip("c2")?.clip.envelope.gain(at: 72_000) == -16, "the music ducks")
        let saved = try Session(contentsOf: package.url) == studio.session
        #expect(saved, "the duck did not save")
        try studio.undo()
        let undone = studio.session == before
        #expect(undone, "one Undo does not give back the point of before")
        #expect(!studio.canUndo, "the duck is more than one undo step")
    }

    /// The Cancel of the banner during the read: no envelope change, no save, no undo step.
    @Test func aCancelledDuckChangesNothing() async throws {
        let studio = try await Studio.open(package.url)
        let (before, bytes) = (studio.session, try sessionBytes())
        let gate = AsyncGate()
        studio.environment.beforeFinalize = { await gate.wait() }

        let ducking = Task { try await duck(studio) }
        await gate.entered()
        #expect(studio.transport == .ducking, "duck hold: \(studio.transport)")
        studio.cancelReadJob()
        gate.open()
        let result = await ducking.result

        switch result {
        case .success(let value): Issue.record("a cancelled duck returned: \(value)")
        case .failure(let error): #expect(error as? StudioError == .duckCancelled, "a cancelled duck threw \(error)")
        }
        #expect(studio.transport == .idle, "after the cancel: \(studio.transport)")
        let unchanged = studio.session == before
        #expect(unchanged && !studio.canUndo, "a cancelled duck changed the session")
        #expect(try sessionBytes() == bytes, "a cancelled duck saved")
    }

    /// Silent speech: the `noSpeech` reason, no envelope change, no save, no undo step.
    @Test func aDuckWithNoSpeechChangesNothing() async throws {
        let fixture = try StudioDuckTests(speech: -.infinity)
        let studio = try await Studio.open(fixture.package.url)
        let (before, bytes) = (studio.session, try fixture.sessionBytes())

        await #expect(throws: StudioError.session(.noSpeech(.zero..<144_000, threshold: -40))) {
            try await fixture.duck(studio)
        }
        #expect(studio.transport == .idle, "after the refusal: \(studio.transport)")
        let unchanged = studio.session == before
        #expect(unchanged && !studio.canUndo, "a duck with no speech changed the session")
        #expect(try fixture.sessionBytes() == bytes, "a duck with no speech saved")
    }

    /// The lists of `Studio.duck` get the named errors of `Session.duckTracks`: an empty speech
    /// list and a track in both lists throw, before any read, and change nothing.
    @Test func badListsThrowTheNamedErrors() async throws {
        let studio = try await Studio.open(package.url)
        let before = studio.session
        await #expect(throws: StudioError.session(.noSpeechTrack)) {
            try await studio.duck(speech: [], music: ["t2"], range: nil, shape: shape)
        }
        await #expect(throws: StudioError.session(.trackInBothDuckLists("t2"))) {
            try await studio.duck(speech: ["t1", "t2"], music: ["t2"], range: nil, shape: shape)
        }
        let unchanged = studio.session == before
        #expect(unchanged && !studio.canUndo && studio.transport == .idle, "a refused duck changed the session")
    }

    /// A range past the session end reads only up to the end: the `noSpeech` scope is the cut range.
    @Test func aRangePastTheEndReadsUpToTheEnd() async throws {
        let fixture = try StudioDuckTests(speech: -.infinity)
        let studio = try await Studio.open(fixture.package.url)
        await #expect(throws: StudioError.session(.noSpeech(100_000..<144_000, threshold: -40))) {
            try await studio.duck(speech: ["t1"], music: ["t2"], range: 100_000..<Frames.limit, shape: fixture.shape)
        }
        #expect(studio.transport == .idle && !studio.canUndo, "after the refusal: \(studio.transport)")
    }
}
