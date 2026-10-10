import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// No app test plays to the real speakers by a forgotten argument (decision 0044). Every studio
/// of a test comes out of `SessionWindow.opened()`, and the counting HAL gives the other
/// environments.
@MainActor
struct ListenSafetyTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    @Test func anOpenedStudioHasNoLiveListenOutput() async throws {
        let (_, studio) = try await timelineModel(try folder.package("a"), app: app)
        #expect(!studio.environment.listenOutput.isLive)
    }

    @Test func theCountingHALEnvironmentHasNoLiveListenOutput() {
        #expect(!CountingHAL().environment.listenOutput.isLive)
    }
}
