import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The idle rule of a studio (architecture-refactor criterion C4): edits, saves, and a new
/// take go only when the transport is idle and no start runs.
@MainActor
struct StudioIdleTests {
    @Test func isIdleOnlyWhenIdleAndNotStarting() async throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "Show.dirigible")
        try Session(sampleRate: 48_000).write(to: url)
        let studio = try await Studio.open(url)
        let states: [(Studio.Transport, Bool, Bool)] = [
            (.idle, false, true),
            (.idle, true, false),
            (.recording(take: 1), false, false),
            (.finalizing(take: 1), false, false),
            (.placing(SegmentName(take: 1, arm: 1, segment: 1)), false, false),
            (.leveling, false, false),
        ]
        for (transport, starting, expected) in states {
            studio.transport = transport
            studio.isStarting = starting
            #expect(studio.isIdle == expected, "isIdle is wrong for \(transport), starting \(starting)")
        }
        studio.transport = .idle
        studio.isStarting = false
    }
}
