import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The refusals and faults of a pre-roll take start (decision 0070, criterion P23): a check
/// refusal plays nothing; a save fault, a failed term read, and a failed engine start stop the
/// Player, write no `<recording>`, and keep the playhead at T.
extension StudioPreRollTests {
    enum Refusal: CaseIterable { case route, access, disk }

    /// Asserts the end of a refused start after the take play began: the Player is stopped,
    /// `session.xml` has no `<recording>`, and the playhead is T = 96,000.
    func expectRefusedAfterThePlay(_ studio: Studio, _ comment: Comment) async throws {
        let reading = try await reading(studio)
        #expect(reading.played == studio.play.feed - 1 && !reading.running, comment)
        #expect(try Session(contentsOf: package.url).recording == nil, comment)
        #expect(studio.session.recording == nil && studio.transport == .idle, comment)
        #expect(studio.playhead == 96_000, comment)
    }

    func faultLine(in logs: URL) throws -> [String: String]? {
        let rows = try journalLines(of: try #require(journalFiles(in: logs).first))
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        return rows.first { $0.count >= 6 && $0[4] == "take" && $0[5] == "pre-roll-fault" }.map(fieldValues)
    }

    /// A check refusal comes before the take play: the Player keeps its last plain play.
    @Test(arguments: Refusal.allCases)
    func refusalPlaysNothing(refusal: Refusal) async throws {
        let free = FreeBytes()
        let studio = try await studio(access: refusal == .access ? .denied : nil, free: free)
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        await studio.perform(.playStop)
        let before = try await reading(studio)
        switch refusal {
        case .route: hal.set("mic", id: nil)
        case .access: break
        case .disk: free.value = 0
        }

        await #expect(throws: StudioError.self) {
            try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        }

        let after = try await reading(studio)
        #expect(after.played == before.played && after.realStart == nil && !after.running, "\(refusal)")
        #expect(studio.session.recording == nil)
    }

    /// The save of `<recording>` fails after the Player start: `Capture/` cannot be made.
    @Test func saveFaultStopsThePlayer() async throws {
        let studio = try await studio()
        let path = package.url.path
        studio.environment.beforeTakeSave = { chmod(path, 0o555) }
        defer { chmod(path, 0o755) }

        do {
            try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
            Issue.record("the start did not throw")
        } catch {
            guard case .file = error else { throw error }
        }

        try await expectRefusedAfterThePlay(studio, "save fault")
    }

    @Test func failedTermReadRefusesThePreRoll() async throws {
        let logs = package.folder.url.appending(path: "logs")
        let studio = try await studio()
        studio.environment.log = startLog(in: logs)
        let fault = HALReadFault(read: .bufferFrames, status: kAudioHardwareNotRunningError)
        studio.environment.outputTerm = { _ in .failure(.read(fault)) }

        await #expect(throws: StudioError.outputTermUnavailable) {
            try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        }

        #expect(try await reading(studio).termFault == .read(fault))
        try await expectRefusedAfterThePlay(studio, "failed read")
        studio.log.drain()
        let line = try faultLine(in: logs)
        #expect(line?["fault"] == "read" && line?["property"] == "fsiz", "\(String(describing: line))")
    }

    /// A late first frame whose segment cannot open: the take reports both the late start and the
    /// write error of the track (P17).
    @Test func writeFailureAfterLateStartIsReported() async throws {
        let studio = try await studio()
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        try FileManager.default.createDirectory(
            at: package.url.appending(path: "Capture/take1-1-1.sidecar"), withIntermediateDirectories: true)
        await input(from: 232_000_000, seconds: 0.5)
        try await studio.stopRecording()

        #expect(studio.lastTake?.lateStarts == ["t1"])
        #expect(studio.lastTake?.gaps == ["t1": .writeFailed])
    }

    /// The take play stops at its first refill (no free descriptor for `f2`): the take does not
    /// start, the error carries that stop, and the journal has the stop.
    @Test func firstRefillStopRefusesThePreRoll() async throws {
        let logs = package.folder.url.appending(path: "logs")
        let studio = try await studio()
        studio.environment.log = startLog(in: logs)
        let url = package.url
        studio.play.player = Player(
            package: { url }, output: .offline, session: studio.session,
            open: { file, clips, rate throws(POSIXError) in
                if file.id == "f2" { throw POSIXError(.EMFILE) }
                return try openMedia(file, in: clips, rate: rate)
            }, readTerm: { _ in .success(.builtIn) }, hostNanos: { Self.hostNow })

        await #expect(throws: StudioError.preRollStopped(.noFreeDescriptor(Int(EMFILE)))) {
            try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        }

        try await expectRefusedAfterThePlay(studio, "first refill stop")
        studio.log.drain()
        let stops = try journalLines(of: try #require(journalFiles(in: logs).first))
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count >= 6 && $0[4] == "take" && $0[5] == "pre-roll-stop" }.map(fieldValues)
        #expect(stops.map { $0["stop"] } == ["noFreeDescriptor(24)"])
    }

    /// The `start:` closure of the Player throws: the term fault of `Reading` refuses the take.
    @Test func failedEngineStartRefusesThePreRoll() async throws {
        let logs = package.folder.url.appending(path: "logs")
        let studio = try await studio()
        studio.environment.log = startLog(in: logs)
        studio.environment.startEngine = { _ in throw NSError(domain: NSOSStatusErrorDomain, code: -10_851) }

        await #expect(throws: StudioError.outputTermUnavailable) {
            try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        }

        #expect(try await reading(studio).termFault == .notStarted(.outputUnavailable(-10_851)))
        try await expectRefusedAfterThePlay(studio, "failed engine start")
        studio.log.drain()
        let line = try faultLine(in: logs)
        #expect(line?["fault"] == "not-started", "\(String(describing: line))")
    }
}
