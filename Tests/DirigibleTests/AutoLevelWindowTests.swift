import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 8b criterion 12: Auto Level and Auto Level per Track on a real Studio. Tracks t1 to t3 each
/// have a clip of the noise file f1 at 0..<2 880 000 (60 s). The noise level changes each 0.5 s,
/// so 1 s of a clip and the whole clip give two different gains.
@Suite(.serialized) @MainActor struct AutoLevelWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()

    init() throws { folder = try TemporaryFolder() }

    func open(device: String = "mic") async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let opened = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 3, seconds: 60, noise: true, device: device))
        #expect(opened.2.makeFirstResponder(opened.3.lanes))
        return opened
    }

    /// The session after `autoLevel` on whole clips, off the main actor.
    func expected(_ clips: Set<ClipID>, _ mode: LevelMode, _ studio: Studio) async -> Session {
        let (session, url) = (studio.session, studio.url)
        return await Task.detached { autoLevel(clips, mode, of: session, in: url).session }.value
    }

    /// 12a. Control: a level of every clip with no selection changes the session.
    @Test func noSelectionDoesNothing() async throws {
        let (model, studio, _, _) = try await open()
        let before = studio.session
        for marks in [Marks(), Marks(inPoint: 0, outPoint: 48_000), Marks(tracks: ["t1"])] {
            model.timeline.marks = marks
            await model.level(.eachClip)
        }
        #expect(studio.session == before, "no selection: the session changed")
        #expect(!studio.canUndo && model.alert == nil, "no selection: an entry or an alert")
        await model.close()
    }

    /// 12b. 1 s of the 60 s clip on t1: the whole clip gets the level.
    @Test func oneClipGetsTheLevelOfTheWholeClip() async throws {
        let (model, studio, _, _) = try await open()
        let before = studio.session
        let whole = try #require(await expected(["c1"], .eachClip, studio).clip("c1")?.clip.gain)
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])

        await model.level(.eachClip)

        #expect(whole != .zero && studio.session.clip("c1")?.clip.gain == whole, "one clip: not the whole-clip gain")
        #expect(studio.session.track("t2") == before.track("t2") && studio.session.track("t3") == before.track("t3"))
        model.undo()
        #expect(studio.session == before, "one clip: the undo did not give back the gain")
        await model.close()
    }

    /// 12c. Two tracks in one entry.
    @Test func severalClipsAreOneEntry() async throws {
        let (model, studio, _, _) = try await open()
        let before = studio.session
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1", "t2"])

        await model.level(.eachClip)

        #expect(studio.session.clip("c1")?.clip.gain != .zero && studio.session.clip("c2")?.clip.gain != .zero)
        #expect(studio.session.track("t3") == before.track("t3"), "several clips: t3 changed")
        model.undo()
        #expect(studio.session == before && !studio.canUndo, "several clips: more than one entry")
        await model.close()
    }

    /// 12d. During a take, Auto Level does nothing and shows no alert, and the take goes on.
    @Test func aTakeRunningChangesNothing() async throws {
        let (model, studio, _, _) = try await open(device: "duo")
        studio.environment = hal.environment
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])
        await model.record()
        #expect(studio.transport == .recording(take: 1))
        await hal.feed(seconds: 0.5)
        let (before, undo) = (studio.session, studio.canUndo)

        await model.level(.eachClip)

        #expect(studio.session == before && studio.canUndo == undo, "take running: the session changed")
        #expect(model.alert == nil, "take running: an alert")
        #expect(studio.transport == .recording(take: 1), "take running: the take ended")
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await model.close()
    }

    /// 12e. With no key window, the command does nothing.
    @Test func noKeyWindowDoesNothing() async throws {
        app.key = nil
        app.timeline(.autoLevel, event: nil, in: nil)
        app.timeline(.autoLevelPerTrack, event: nil, in: nil)
    }

    /// 12f. With the focus in a track name field, Command-L levels and the field keeps its text.
    @Test func aFocusedFieldKeepsItsText() async throws {
        let (model, studio, window, _) = try await open()
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])
        let editor = try await focusName(in: window)
        let text = editor.string

        app.timeline(.autoLevel, event: commandKey("l", code: 37, in: window), in: window)

        await until("Command-L levels the clip") { studio.canUndo }
        #expect(editor.string == text, "focused field: the text changed to \(editor.string)")
        await model.close()
    }

    /// 12g. Option-Command-L gives the two clips of t1 one delta.
    @Test func perTrackGivesOneDelta() async throws {
        let (model, studio, _, _) = try await open()
        model.edit { session throws(SessionError) in
            let right = try session.split("c1", at: 1_440_000)
            try session.setGain(Gain(dB: 3)!, clip: right)
        }
        let right = try #require(studio.session.track("t1")?.clips.last?.id)
        let target = await expected(["c1", right], .equallyPerTrack, studio)
        model.timeline.marks = Marks(inPoint: 0, outPoint: 2_880_000, tracks: ["t1"])

        app.timeline(.autoLevelPerTrack, event: nil, in: nil)

        await until("Option-Command-L levels the clips") { studio.session.clip("c1")?.clip.gain != .zero }
        let left = try #require(studio.session.clip("c1")?.clip.gain.dB)
        let moved = try #require(studio.session.clip(right)?.clip.gain.dB)
        #expect(abs(moved - left - 3) <= 0.001, "per track: \(left) and \(moved)")
        #expect(studio.session == target, "per track: not the gains of autoLevel")
        await model.close()
    }
}
