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
        case .timelineDragModeCue: "%@ drag mode"
        case .menuEditDragModeOverwrite: "Overwrite"
        case .menuEditDragModeNoOverlap: "No Overlap"
        case .menuEditDragModeCrossfade: "Crossfade"
        case .menuEditDragModeShuffle: "Shuffle"
        default: "x"
        }
    }

    func subtitle(_ mode: DragMode, preRoll: Bool = false) -> String {
        subtitleText(
            rate: 48_000, recordTimeLeft: nil, preRoll: preRoll, dragMode: mode,
            locale: Locale(identifier: "en_US"), text: Self.english)
    }

    @Test func theCueShowsOnlyOutsideOverwrite() {
        #expect(subtitle(.overwrite) == "48 kHz")
        #expect(subtitle(.noOverlap) == "48 kHz · No Overlap drag mode")
        #expect(subtitle(.crossfade) == "48 kHz · Crossfade drag mode")
        #expect(subtitle(.shuffle) == "48 kHz · Shuffle drag mode")
    }

    @Test func thePreRollTakesThePlaceOfTheCue() {
        #expect(subtitle(.shuffle, preRoll: true) == "48 kHz · Pre-roll")
        #expect(subtitle(.overwrite, preRoll: true) == "48 kHz · Pre-roll")
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
        #expect(ChromeState(model: model).subtitle.hasSuffix(" · " + cue))
        await model.close()
    }
}
