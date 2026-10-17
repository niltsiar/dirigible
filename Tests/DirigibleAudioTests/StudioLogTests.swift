import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// C41: the one public seam that carries the journal of the front end into a studio (decision 0059).
@MainActor
struct StudioLogTests {
    enum Entry: CaseIterable { case open, create }

    let folder: TemporaryFolder

    init() throws { folder = try TemporaryFolder() }

    /// The live environment: an unknown track throws in the route check, before a HAL call or a
    /// read of the microphone access.
    @Test(arguments: Entry.allCases) func aStudioFromOpenOrCreateWritesToItsLog(_ entry: Entry) async throws {
        let logs = folder.url.appending(path: "logs")
        let log = startLog(in: logs)
        let package = folder.url.appending(path: "Show.dirigible")
        let studio: Studio
        switch entry {
        case .open:
            try Session(sampleRate: 48_000).write(to: package)
            studio = try await Studio.open(package, log: log)
        case .create:
            studio = try await Studio.create(package, sampleRate: 48_000, log: log)
        }

        await #expect(throws: StudioError.session(.unknownTrack("t9"))) {
            try await studio.startRecording(armed: ["t9"])
        }

        log.drain()
        let lines = try journalLines(of: try #require(journalFiles(in: logs).first))
        #expect(lines.contains { $0.contains("\ttake\tstart-request\tarmed=1") }, "lines: \(lines)")
        #expect(studio.log === log)
    }
}
