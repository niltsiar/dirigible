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

    func open(device: String = "mic", in parent: URL? = nil) async throws
        -> (SessionWindow, Studio, NSWindow, TimelineScrollView)
    {
        let opened = try await openLanes(
            app,
            try await timelinePackage(in: parent ?? folder.url, tracks: 3, seconds: 60, noise: true, device: device))
        #expect(opened.2.makeFirstResponder(opened.3.lanes))
        return opened
    }

    /// The session after `autoLevel` on whole clips, off the main actor.
    func expected(_ clips: Set<ClipID>, _ mode: LevelMode, _ studio: Studio) async -> Session {
        let (session, url) = (studio.session, studio.url)
        return await Task.detached { autoLevel(clips, mode, of: session, in: url).session }.value
    }

    /// Mutes t3, then levels `marks` with `mode`. Records an issue when the clips of `leveled` do
    /// not get the gains of `autoLevel`, when another clip changes, or when one Undo does not give
    /// back the session before the level.
    func expectLevel(
        _ marks: Marks, _ mode: LevelMode, levels leveled: Set<ClipID>, _ label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let parent = folder.url.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let (model, studio, _, _) = try await open(in: parent)
        model.edit { session throws(SessionError) in try session.setMuted(true, tracks: ["t3"]) }
        let before = studio.session
        let target = await expected(leveled, mode, studio)
        model.timeline.marks = marks

        await model.level(mode)

        for clip: ClipID in ["c1", "c2", "c3"] {
            let gain = studio.session.clip(clip)?.clip.gain
            let wanted = leveled.contains(clip) ? target.clip(clip)?.clip.gain : .zero
            #expect(
                gain == wanted && (gain != .zero) == leveled.contains(clip),
                "\(label): \(clip) gain \(String(describing: gain)), not \(String(describing: wanted))",
                sourceLocation: sourceLocation)
        }
        model.undo()
        let undone = studio.session == before
        #expect(
            undone && model.alert == nil, "\(label): one Undo does not give back the session",
            sourceLocation: sourceLocation)
        await model.close()
    }

    /// C1, C4: with the empty selection, each command levels every clip, also on the muted t3.
    @Test func noSelectionLevelsEveryClip() async throws {
        try await expectLevel(Marks(), .eachClip, levels: ["c1", "c2", "c3"], "no selection")
        try await expectLevel(Marks(inPoint: 0), .equallyPerTrack, levels: ["c1", "c2", "c3"], "in point only")
    }

    /// C1b: a track-only selection levels every clip of its tracks.
    @Test func aTrackOnlySelectionLevelsItsTracks() async throws {
        try await expectLevel(Marks(tracks: ["t1", "t3"]), .eachClip, levels: ["c1", "c3"], "tracks t1 and t3")
    }

    /// C1c: a range with no track touches the clips of all tracks, as I and O do.
    @Test func aRangeWithNoTrackUsesAllTracks() async throws {
        try await expectLevel(
            Marks(inPoint: 48_000, outPoint: 96_000), .eachClip, levels: ["c1", "c2", "c3"], "range with no track")
    }

    /// C4: a range on the muted t3 only levels c3 (decision 0039).
    @Test func aMutedTrackGetsItsLevel() async throws {
        try await expectLevel(
            Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t3"]), .eachClip, levels: ["c3"], "muted t3")
    }

    /// C1b, plan gate P7: a click on the t1 header from the empty selection, then Cmd-L.
    @Test func aHeaderClickLevelsItsTrack() async throws {
        let (model, studio, _, _) = try await open()
        let target = await expected(["c1"], .eachClip, studio)
        model.clickHeader("t1", flags: [])
        #expect(model.timeline.selection == .range(Marks(tracks: ["t1"])), "header click: \(model.timeline.selection)")

        app.timeline(.autoLevel, event: nil, in: nil)

        await until("Command-L levels c1") { studio.session.clip("c1")?.clip.gain != .zero }
        #expect(studio.session.clip("c1")?.clip.gain == target.clip("c1")?.clip.gain, "header click: c1")
        #expect(
            studio.session.clip("c2")?.clip.gain == .zero && studio.session.clip("c3")?.clip.gain == .zero,
            "header click: c2 or c3 changed")
        await model.close()
    }

    /// C3: a selection with no clip beeps one time and changes nothing.
    @Test func aSelectionWithNoClipBeeps() async throws {
        let (model, studio, _, _) = try await open()
        var beeps = 0
        model.beep = { beeps += 1 }
        model.edit { session throws(SessionError) in try session.addTrack("t4", name: "t4", layout: .mono) }
        let past = Marks(inPoint: 3_000_000, outPoint: 3_048_000)
        let values: [(Selection, String)] = [
            (.range(Marks(inPoint: 3_000_000, outPoint: 3_048_000, tracks: ["t1"])), "gap on t1"),
            (.range(past), "range with no track past the end"),
            (.range(Marks(tracks: ["t4"])), "track t4 with no clip"),
            (ClipSet(["gone"]).map { .clips($0) } ?? .none, "stale clip set"),
        ]
        for (selection, label) in values {
            let (before, undo, count) = (studio.session, studio.canUndo, beeps)
            model.timeline.selection = selection
            await model.level(.eachClip)
            let same = studio.session == before
            #expect(same && studio.canUndo == undo, "\(label): the session or the undo changed")
            #expect(beeps == count + 1, "\(label): beeps \(beeps - count)")
            #expect(model.timeline.selection == selection, "\(label): the selection changed")
        }
        await model.close()
    }

    /// C9: the titles say All only for the empty selection, and with no key window they do not.
    @Test func theTitlesFollowTheScope() async throws {
        let (model, _, _, _) = try await open()
        let cases: [(Selection, L10n, L10n)] = [
            (.none, .menuToolsLevelAll, .menuToolsLevelTrackAll),
            (.range(Marks(inPoint: 0)), .menuToolsLevelAll, .menuToolsLevelTrackAll),
            (.range(Marks(tracks: ["t1"])), .menuToolsLevel, .menuToolsLevelTrack),
            (.range(Marks(inPoint: 0, outPoint: 48_000)), .menuToolsLevel, .menuToolsLevelTrack),
            (.range(Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])), .menuToolsLevel, .menuToolsLevelTrack),
            (
                .range(Marks(inPoint: 3_000_000, outPoint: 3_048_000, tracks: ["t1"])), .menuToolsLevel,
                .menuToolsLevelTrack
            ),
            (ClipSet(["c1"]).map { .clips($0) } ?? .none, .menuToolsLevel, .menuToolsLevelTrack),
        ]
        for (selection, title, trackTitle) in cases {
            model.timeline.selection = selection
            #expect(app.levelTitle(.autoLevel, for: model) == title, "\(selection)")
            #expect(app.levelTitle(.autoLevelPerTrack, for: model) == trackTitle, "\(selection) per track")
        }
        #expect(app.levelTitle(.autoLevel, for: nil) == .menuToolsLevel, "no key window")
        #expect(app.levelTitle(.autoLevelPerTrack, for: nil) == .menuToolsLevelTrack, "no key window per track")
        #expect(app.levelTitle(.fade, for: model) == nil, "another command")
        await model.close()
    }

    /// C10: the items are off with no clip, and a selection does not turn them off.
    @Test func theItemsAreOffWithNoClip() async throws {
        let (model, studio, _, _) = try await open()
        model.timeline.marks = Marks(inPoint: 3_000_000, outPoint: 3_048_000, tracks: ["t1"])
        #expect(model.isOn(.autoLevel) && model.isOn(.autoLevelPerTrack), "a range over a gap turns the items off")
        let tracks = studio.session.tracks.map(\.id)
        model.edit { session throws(SessionError) in try session.clear(.zero..<Frames.limit, on: tracks) }
        #expect(studio.session.tracks.allSatisfy { $0.clips.isEmpty }, "the clips stay")
        #expect(!model.isOn(.autoLevel) && !model.isOn(.autoLevelPerTrack), "no clip: the items are on")
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
        var beeps = 0
        model.beep = { beeps += 1 }
        #expect(!model.isOn(.autoLevel) && !model.isOn(.autoLevelPerTrack), "take running: the items are on")

        await model.level(.eachClip)

        #expect(studio.session == before && studio.canUndo == undo, "take running: the session changed")
        #expect(model.alert == nil && beeps == 0, "take running: an alert or a beep")
        #expect(studio.transport == .recording(take: 1), "take running: the take ended")
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        #expect(model.isOn(.autoLevel), "after the take: the item is off")
        await model.close()
    }

    /// 12e. With no key window, the command does nothing.
    @Test func noKeyWindowDoesNothing() async throws {
        app.key = nil
        app.timeline(.autoLevel, event: nil, in: nil)
        app.timeline(.autoLevelPerTrack, event: nil, in: nil)
    }

    /// 12f. With the focus in a track name field and a typed name, Command-L saves the name first,
    /// as Record does, then levels. Code gate 1 K1: the level made the field read-only, and the name
    /// went with no alert.
    @Test func aFocusedFieldKeepsItsText() async throws {
        let (model, studio, window, _) = try await open()
        model.timeline.marks = Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"])
        let editor = try await focusName(in: window)
        editor.selectAll(nil)
        editor.insertText("Guest", replacementRange: editor.selectedRange())
        await until("the typed name is a draft") { model.drafts["t1"] == "Guest" }

        app.timeline(.autoLevel, event: commandKey("l", code: 37, in: window), in: window)

        await until("Command-L levels the clip") { studio.session.clip("c1")?.clip.gain != .zero }
        #expect(
            studio.session.track("t1")?.name == "Guest",
            "focused field: the typed name is \(String(describing: studio.session.track("t1")?.name))")
        #expect(model.drafts["t1"] == nil, "focused field: the draft is committed")
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
