import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Edit > Drag Mode (C45, C59): the stored mode, the checkmarks, and the keys that ignore the mode.
@Suite(.serialized) @MainActor struct DragModeMenuTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func defaults() throws -> UserDefaults {
        let name = "DragModeMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theModeStaysAfterARestart() throws {
        let defaults = try defaults()
        #expect(AppDelegate(recordings: nil, defaults: defaults).dragMode == .overwrite, "no value")
        AppDelegate(recordings: nil, defaults: defaults).dragMode = .shuffle
        #expect(AppDelegate(recordings: nil, defaults: defaults).dragMode == .shuffle)
        defaults.set("bogus", forKey: AppDelegate.dragModeKey)
        #expect(AppDelegate(recordings: nil, defaults: defaults).dragMode == .overwrite, "an unknown value")
    }

    @Test func theCurrentModeHasTheOnlyCheckmark() {
        let items = DragModeItems(app: app)
        for current in DragMode.allCases {
            app.dragMode = current
            #expect(DragMode.allCases.filter { items.checked($0).wrappedValue } == [current], "\(current)")
        }
        items.checked(.crossfade).wrappedValue = true
        #expect(app.dragMode == .crossfade, "a click on another item sets the mode")
        items.checked(.crossfade).wrappedValue = false
        #expect(app.dragMode == .crossfade, "a click on the checked item keeps the mode")
    }

    /// C59 (U45): Command-Right makes b cover the head of c in every mode: c is cut, no alert, one undo.
    @Test func theNudgeKeysOverwriteInEveryMode() async throws {
        for mode in DragMode.allCases {
            let place = folder.url.appending(path: mode.rawValue)
            try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
            let (model, studio, _, _) = try await openLanes(
                app, try await timelinePackage(in: place, tracks: 1, seconds: 60))
            _ = try studio.edit(ripple: false) { s throws(SessionError) in
                try s.splitClips(at: [48_000, 96_000], on: ["t1"])
            }
            let before = studio.session
            app.dragMode = mode
            model.timeline.marks = Marks(inPoint: 40_000, outPoint: 96_000, tracks: ["t1"])

            model.run(.nudgeRight)

            let clips = Array(try #require(studio.session.track("t1")).clips)
            #expect(clips.map(\.start) == [0, 48_480, 96_480], "\(mode)")
            #expect(model.alert == nil, "\(mode)")
            model.undo()
            #expect(studio.session == before, "\(mode): one undo")
            await model.close()
        }
    }
}
