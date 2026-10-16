import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Mute and solo C7 d and C8 d (decision 0039): during a take, M, S, and the Track items change
/// nothing, and the arm state and the take go on.
extension EditTakeTests {
    @Test func muteAndSoloDoNothingDuringATake() async throws {
        let model = await app.open(try await package())
        let studio = try #require(await model.opened() ? model.studio : nil)
        studio.environment = hal.environment
        await model.record()
        try #require(studio.transport == .recording(take: 1))
        let armed = model.armed
        model.timeline.marks = Marks(tracks: ["t1"])

        model.setFlag(.muted, true, track: "t1", all: false)
        model.setFlag(.soloed, true, track: "t2", all: true)
        model.run(.muteTracks)
        model.run(.soloTracks)

        #expect(!model.canEdit, "the buttons are off during a take")
        #expect(!studio.session.tracks.contains { $0.isMuted || $0.isSoloed }, "no flag changed")
        #expect(model.armed == armed && studio.transport == .recording(take: 1), "the arm state and the take stay")
        await hal.feed(seconds: 0.2)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await model.close()
    }
}
