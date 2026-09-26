import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Edit-commands criterion 23: Show Clips in Finder with an injected reveal function. Tracks t1 to
/// t3 each have a clip of f1 (on disk) at 0..<2 880 000; the setup puts a clip x of f2 at 0..<48 000
/// on t2.
@Suite(.serialized) @MainActor struct RevealTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let revealed = Revealed()

    init() throws { folder = try TemporaryFolder() }

    /// The URLs of each reveal call.
    @MainActor final class Revealed {
        var calls: [[String]] = []
    }

    /// With `f2`, the file of x is on disk too. The write runs off the main actor.
    func open(f2: Bool) async throws -> (SessionWindow, Studio) {
        let package = try await timelinePackage(in: folder.url, tracks: 3, seconds: 60, audio: true)
        if f2 {
            try await Task.detached {
                try Data([0]).write(to: package.appending(path: "\(clipsFolderName)/f2.wav"))
            }.value
        }
        let (model, studio, _, _) = try await openLanes(app, package)
        app.reveal = { [revealed] urls in revealed.calls.append(urls.map(\.lastPathComponent)) }
        try studio.edit { s throws(SessionError) in
            try s.addFile(AudioFile(id: "f2", path: "f2.wav", layout: .mono, length: 48_000))
            try s.clear(0..<48_000, on: "t2")
            try s.place(Clip(id: "x", file: "f2", start: 0, offset: 0, length: 48_000), on: "t2")
        }
        return (model, studio)
    }

    /// Only the files of the clips that overlap the range on the selected tracks. Control: the
    /// files of every clip of the session add f1.
    @Test func theFilesOfTheSelection() async throws {
        let (model, _) = try await open(f2: true)
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t2"])

        await model.showClipsInFinder()

        #expect(revealed.calls == [["f2.wav"]])
        await model.close()
    }

    @Test func noSelectionRevealsEveryClipFile() async throws {
        let (model, _) = try await open(f2: true)

        await model.showClipsInFinder()

        #expect(revealed.calls == [["f1.wav", "f2.wav"]])
        await model.close()
    }

    /// f2 is not on disk: with no selection only f1 goes; with x selected, nothing goes (a beep).
    /// Control: a reveal with no existence filter gives f2.
    @Test func aMissingFileIsLeftOutAndNoneBeeps() async throws {
        let (model, studio) = try await open(f2: false)
        let before = studio.session

        await model.showClipsInFinder()
        model.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t2"])
        await model.showClipsInFinder()

        #expect(revealed.calls == [["f1.wav"]])
        #expect(studio.session == before && model.alert == nil)
        await model.close()
    }
}
