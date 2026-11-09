import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The Drag Mode cue in the window subtitle (C48).
@Suite(.serialized) @MainActor struct DragModeCueTests {
    static let english: (L10n) -> String = { key in
        switch key {
        case .subtitlePreRoll: "Pre-roll"
        case .subtitleTracks: "Tracks"
        case .timelineDragModeCue: "Drag Mode: %@"
        case .menuEditDragModeOverwrite: "Overwrite"
        case .menuEditDragModeNoOverlap: "No Overlap"
        case .menuEditDragModeCrossfade: "Crossfade"
        case .menuEditDragModeShuffle: "Shuffle"
        default: "x"
        }
    }

    func subtitle(_ mode: DragMode, preRoll: Bool = false) -> String {
        subtitleText(
            rate: 48_000, tracks: 3, recordTimeLeft: nil, preRoll: preRoll, dragMode: mode,
            locale: Locale(identifier: "en_US"), text: Self.english)
    }

    @Test func theCueShowsOnlyOutsideOverwrite() {
        #expect(subtitle(.overwrite) == "48 kHz · Tracks 3")
        #expect(subtitle(.noOverlap) == "Drag Mode: No Overlap · 48 kHz · Tracks 3")
        #expect(subtitle(.crossfade) == "Drag Mode: Crossfade · 48 kHz · Tracks 3")
        #expect(subtitle(.shuffle) == "Drag Mode: Shuffle · 48 kHz · Tracks 3")
    }

    @Test func theCueComesAfterPreRoll() {
        #expect(subtitle(.shuffle, preRoll: true) == "Pre-roll · Drag Mode: Shuffle · 48 kHz · Tracks 3")
        #expect(subtitle(.overwrite, preRoll: true) == "Pre-roll · 48 kHz · Tracks 3")
    }

    /// The window state reads the app mode, so a menu click changes the subtitle.
    @Test func theWindowSubtitleFollowsTheAppMode() async throws {
        let folder = try TemporaryFolder()
        let app = AppDelegate(recordings: nil)
        let (model, _) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 10), app: app)
        let cue = String(format: L10n.timelineDragModeCue.text, L10n.menuEditDragModeShuffle.text)

        #expect(!ChromeState(model: model).subtitle.contains(cue))
        app.dragMode = .shuffle
        #expect(ChromeState(model: model).subtitle.hasPrefix(cue + " · "))
        await model.close()
    }
}
