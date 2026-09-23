import Foundation
import Testing

@testable import DirigibleCore

/// The save reads its own XML back before it replaces session.xml. A session that breaks an
/// invariant (here set past the edits) fails the save and leaves the old file.
struct WriteGuardTests {
    @Test func aSessionThatWouldNotReadBackIsNotSaved() throws {
        let package = FileManager.default.temporaryDirectory
            .appending(path: "WriteGuardTests-\(UUID().uuidString)/Episode.dirigible")
        try Session(sampleRate: 48_000).write(to: package)
        let old = try Data(contentsOf: package.appending(path: "session.xml"))

        var broken = Session(sampleRate: 48_000)
        broken.recording = Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 1, armedTracks: ["ghost"])

        #expect(throws: SessionFileError.wouldNotReadBack(.invalidSession(.unknownTrack("ghost")))) {
            try broken.write(to: package)
        }
        #expect(try Data(contentsOf: package.appending(path: "session.xml")) == old)
    }
}
