import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The public start (criteria 14, 15, and 24): the lookup, the microphone access, and the file
/// work run off the main actor, and a start that throws changes nothing.
@MainActor
struct StartRecordingTests {
    let folder: TemporaryFolder
    let url: URL
    var sessionXML: URL { url.appending(path: "session.xml") }
    var capture: URL { url.appending(path: "Capture") }
    let mic = InputDevice(
        uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    /// Track `t1` on channel 1 of `mic`.
    init() throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRoute(Route(deviceUID: "mic", channels: .mono(1)), track: "t1")
        try session.write(to: url)
    }

    func studio(_ hal: TestHAL, access: MicrophoneAccess? = nil) async throws -> Studio {
        let studio = try await Studio.open(url)
        studio.environment = .test(hal, access: access)
        return studio
    }

    func isRecording(_ studio: Studio) -> Bool {
        if case .recording = studio.transport { return true }
        return false
    }

    /// A new take clears the result of the last take, so `lastTake` never describes an older
    /// take while a new one records. Control: a start that throws keeps it.
    @Test(arguments: [false, true])
    func aNewTakeClearsTheLastResult(startThrows: Bool) async throws {
        let hal = TestHAL([mic])
        let studio = try await studio(hal)
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        try await studio.stopRecording()
        let first = try #require(studio.lastTake)

        if startThrows {
            hal.set("mic", id: nil)
            await #expect(throws: StudioError.deviceMissing("t1")) {
                try await studio.startRecording(armed: ["t1"], playhead: 0)
            }
            #expect(studio.lastTake == first)
        } else {
            try await studio.startRecording(armed: ["t1"], playhead: 0)
            #expect(studio.lastTake == nil)
            try await studio.stopRecording()
            // Take 1 has no segment, so the second take is number 1 too.
            #expect(studio.lastTake == first)
        }
    }

    // MARK: Criterion 24

    /// The lookup waits on the gate while the main actor runs the test. Control: after the
    /// stop, an edit and a new start succeed.
    @Test func theStartWaitsOffTheMainActorAndEverythingElseIsBusy() async throws {
        let hal = TestHAL([mic])
        hal.holdLookUps()
        let studio = try await studio(hal)

        let first = Task { try await studio.startRecording(armed: ["t1"], playhead: 0) }
        await until("the start did not reach the lookup") { hal.heldLookUps == 1 }
        await #expect(throws: StudioError.busy) { try await studio.startRecording(armed: ["t1"], playhead: 0) }
        #expect(throws: StudioError.busy) {
            try studio.edit { session throws(SessionError) in try session.addTrack("t2", name: "Guest", layout: .mono) }
        }
        await #expect(throws: StudioError.busy) { try await studio.stopRecording() }
        hal.releaseLookUps()
        try await first.value

        #expect(studio.transport == .recording(take: 1))
        try await studio.stopRecording()
        try studio.edit { session throws(SessionError) in try session.addTrack("t2", name: "Guest", layout: .mono) }
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        #expect(isRecording(studio))
        try await studio.stopRecording()
    }

    // MARK: Criterion 14

    @Test(arguments: [nil, .denied, .notDetermined] as [MicrophoneAccess?])
    func theStartReadsTheMicrophoneAccess(access: MicrophoneAccess?) async throws {
        let before = try Data(contentsOf: sessionXML)
        let studio = try await studio(TestHAL([mic]), access: access)

        guard let access else {
            try await studio.startRecording(armed: ["t1"], playhead: 0)
            #expect(studio.transport == .recording(take: 1))
            try await studio.stopRecording()
            return
        }
        await #expect(throws: StudioError.microphoneAccess(access)) {
            try await studio.startRecording(armed: ["t1"], playhead: 0)
        }
        #expect(studio.transport == .idle)
        #expect(try Data(contentsOf: sessionXML) == before)
        #expect(!FileManager.default.fileExists(atPath: capture.path))
    }

    // MARK: Criterion 15, first part

    /// The lookup runs before the access read, so a missing device throws `.deviceMissing` also
    /// with no access. Control: the device is present, and the take starts.
    @Test(arguments: [false, true])
    func aDeviceThatTheLookUpDoesNotFindThrowsAndChangesNothing(present: Bool) async throws {
        let before = try Data(contentsOf: sessionXML)
        let studio = try await studio(TestHAL(present ? [mic] : []), access: present ? nil : .denied)

        guard !present else {
            try await studio.startRecording(armed: ["t1"], playhead: 0)
            #expect(studio.transport == .recording(take: 1))
            try await studio.stopRecording()
            return
        }
        await #expect(throws: StudioError.deviceMissing("t1")) {
            try await studio.startRecording(armed: ["t1"], playhead: 0)
        }
        #expect(studio.transport == .idle)
        #expect(try Data(contentsOf: sessionXML) == before)
        #expect(!FileManager.default.fileExists(atPath: capture.path))
    }
}
