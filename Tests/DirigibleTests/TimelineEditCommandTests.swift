import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Close Gaps, Roll Edit to Playhead, Slip Content Left, and Slip Content Right in the window
/// (C4, C11, C12, C13, C15; decision 0036). 48 kHz. File f1 is 2,880,000 frames, and f2 is 48,000.
/// Track t1 holds a at 0 ..< 48,000, b at 72,000 ..< 120,000, and c at 144,000 ..< 192,000, with a
/// gap before b and before c. Track t2 holds d (file f2, at its end, so it cannot grow) at
/// 0 ..< 48,000, then e at 48,000 ..< 96,000 and f at 96,000 ..< 144,000, all touching.
@Suite(.serialized) @MainActor struct TimelineEditCommandTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()

    init() throws { folder = try TemporaryFolder() }

    /// The tracks have routes, so a take can start on them.
    func package() async throws -> URL {
        let url = folder.url.appending(path: "trims.dirigible")
        try await Task.detached {
            var session = Session(sampleRate: 48_000)
            try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 2_880_000))
            try session.addFile(AudioFile(id: "f2", path: "f2.wav", layout: .mono, length: 48_000))
            for (n, channel) in [(1, 1), (2, 2)] {
                let track = TrackID("t\(n)")
                try session.addTrack(track, name: "T\(n)", layout: .mono)
                try session.setRoute(Route.device(uid: "duo", channels: .mono(channel)), track: track)
            }
            for (id, track, start) in [
                ("a", "t1", 0), ("b", "t1", 72_000), ("c", "t1", 144_000), ("e", "t2", 48_000), ("f", "t2", 96_000),
            ] as [(ClipID, TrackID, Int)] {
                try session.place(
                    Clip(id: id, file: "f1", start: Frames(start), offset: Frames(start + 96_000), length: 48_000),
                    on: track)
            }
            try session.place(Clip(id: "d", file: "f2", start: 0, offset: 0, length: 48_000), on: "t2")
            try session.write(to: url)
        }.value
        return url
    }

    func opened() async throws -> (SessionWindow, Studio, () -> Int) {
        let (model, studio) = try await timelineModel(try await package(), app: app)
        var count = 0
        model.beep = { count += 1 }
        return (model, studio, { count })
    }

    func clip(_ id: ClipID, _ studio: Studio) -> Clip { studio.session.clip(id)!.clip }

    func set(_ ids: ClipID...) -> Selection { ClipSet(Set(ids)).map { .clips($0) } ?? .none }

    /// C11. A clip set of two or more clips moves; a range that holds clips whole moves; a set of
    /// one clip, no selection, and a range that holds no clip beep and change nothing; during a take
    /// the item is off. Control: a command that moves nothing but records an undo entry fails.
    @Test func closeGapsInEachStartState() async throws {
        let (model, studio, beeps) = try await opened()
        model.timeline.selection = set("a", "b", "c")
        model.run(.closeGaps)
        #expect(clip("b", studio).start == 48_000 && clip("c", studio).start == 96_000, "the set closes its gaps")
        #expect(clip("a", studio).start == 0 && beeps() == 0)
        try studio.undo()

        model.timeline.selection = .range(Marks(inPoint: 0, outPoint: 200_000, tracks: ["t1"]))
        model.run(.closeGaps)
        #expect(clip("b", studio).start == 48_000, "a range that holds the clips whole closes them too")
        try studio.undo()

        let before = (studio.session, studio.sessionRevision)
        for selection in [
            set("b"), .none, .range(Marks(inPoint: 48_000, outPoint: 72_000, tracks: ["t1"])),
            .range(Marks(inPoint: 0, outPoint: 200_000, tracks: ["t2"])),
        ] {
            model.timeline.selection = selection
            model.run(.closeGaps)
        }
        #expect(beeps() == 4, "each of the four states beeps")
        #expect(studio.session == before.0 && studio.sessionRevision == before.1 && model.alert == nil)
        await model.close()
    }

    /// C4, window part: a Close Gaps with no gap to close records no undo entry.
    @Test func closeGapsWithNoGapRecordsNoUndo() async throws {
        let (model, studio, beeps) = try await opened()
        model.timeline.selection = set("d", "e", "f")
        let revision = studio.sessionRevision
        model.run(.closeGaps)
        #expect(beeps() == 1 && studio.sessionRevision == revision && !studio.canUndo)
        await model.close()
    }

    /// C11. The lane menu shows Close Gaps on a clip set of two or more clips, and its item runs the
    /// Edit item. It is no ripple, so a pending take does not hide it, but a take does.
    @Test func closeGapsInTheLaneMenu() async throws {
        func commands(clips: Int, canEdit: Bool = true, canRipple: Bool = true) -> [TimelineCommand] {
            LaneMenu.groups(
                selection: true, clips: true, stereo: false, denoise: false, restore: false, clipboard: false,
                split: false, canEdit: canEdit, canRipple: canRipple, closeGaps: clips >= 2
            ).joined().map(\.command)
        }
        #expect(commands(clips: 2).contains(.closeGaps))
        #expect(!commands(clips: 1).contains(.closeGaps), "a set of one clip hides it")
        #expect(commands(clips: 2, canRipple: false).contains(.closeGaps), "it is no ripple")
        #expect(!commands(clips: 2, canEdit: false).contains(.closeGaps), "a take hides it")

        let (model, studio, _) = try await opened()
        let (_, view) = standaloneLanes(model, studio)
        model.timeline.selection = set("a", "b")
        let title = L10n.menuEditCloseGaps.text
        let menu = try #require(view.lanes.menu(for: try mouse(.rightMouseDown, NSPoint(x: 150, y: 10), in: view)))
        let item = try #require(menu.items.first { $0.title == title })
        #expect(item.isEnabled && item.keyEquivalent.isEmpty)
        let action = try #require(item.action)
        NSApp.sendAction(action, to: item.target, from: item)
        #expect(clip("b", studio).start == 48_000, "the lane item ran Close Gaps")
        model.timeline.selection = set("a")
        let single = try #require(view.lanes.menu(for: try mouse(.rightMouseDown, NSPoint(x: 40, y: 10), in: view)))
        #expect(!single.items.contains { $0.title == title }, "one clip hides it")
        await model.close()
    }

    /// C12. Each start state of Roll Edit to Playhead. On t2 the playhead at 60,000 is in e, nearer
    /// to the join with d (12,000) than to the join with f (36,000); d cannot grow, so the track
    /// skips. At 90,000 the join with f is nearer and rolls.
    @Test func rollToPlayheadInEachStartState() async throws {
        let (model, studio, beeps) = try await opened()
        model.timeline.selection = .range(Marks(tracks: ["t2"]))

        await studio.perform(.seek(.frame(90_000)))
        model.run(.rollToPlayhead)
        #expect(clip("e", studio).length == 42_000 && clip("f", studio).start == 90_000, "the nearer join rolls")
        #expect(beeps() == 0)
        try studio.undo()

        await studio.perform(.seek(.frame(60_000)))
        let before = studio.session
        model.run(.rollToPlayhead)
        #expect(studio.session == before && beeps() == 1, "past the limit of d: that track skips, with a beep")

        model.timeline.selection = .range(Marks(tracks: ["t1"]))
        for frame in [60_000, 48_000, 100_000, 190_000] as [Frames] {
            await studio.perform(.seek(.frame(frame)))
            model.run(.rollToPlayhead)
        }
        #expect(studio.session == before && beeps() == 5, "a gap, no join, and a frame in c with no join beep")
        await model.close()
    }

    /// C15. A roll on two tracks is one undo entry; each command is one entry, and Undo gives the
    /// session before.
    @Test func eachEditIsOneUndoEntry() async throws {
        let (model, studio, _) = try await opened()
        let start = studio.session
        await studio.perform(.seek(.frame(90_000)))
        let cases: [(TimelineCommand, Selection)] = [
            (.closeGaps, set("a", "b", "c")), (.rollToPlayhead, .range(Marks(tracks: ["t2"]))),
            (.slipLeft, set("a", "b")), (.slipRight, set("e")),
        ]
        for (command, selection) in cases {
            model.timeline.selection = selection
            let revision = studio.sessionRevision
            model.run(command)
            #expect(studio.sessionRevision == revision + 1, "\(command) is one edit")
            try studio.undo()
            #expect(studio.session == start, "\(command) undoes whole")
        }
        await model.close()
    }

    /// C13. Slip Content Left moves the audio 10 ms (480 frames) left under the clip: the file offset
    /// grows. A set, a range that holds clips, no clip (beep), a clip at its limit (beep, no change).
    @Test func slipInEachStartState() async throws {
        let (model, studio, beeps) = try await opened()
        model.timeline.selection = set("a", "c")
        model.run(.slipLeft)
        #expect(clip("a", studio).offset == 96_480 && clip("c", studio).offset == 240_480, "the set slips")
        #expect(clip("b", studio).offset == 168_000 && clip("a", studio).start == 0, "no other clip, no start")
        model.run(.slipRight)
        model.run(.slipRight)
        #expect(clip("a", studio).offset == 95_520)

        model.timeline.selection = .range(Marks(inPoint: 0, outPoint: 200_000, tracks: ["t1"]))
        model.run(.slipRight)
        #expect(clip("b", studio).offset == 167_520, "a range that holds the clips slips them")
        #expect(beeps() == 0)

        let before = studio.session
        model.timeline.selection = .none
        model.run(.slipLeft)
        model.timeline.selection = set("d")
        model.run(.slipLeft)
        model.timeline.selection = set("d", "e")
        model.run(.slipRight)
        #expect(beeps() == 3, "no clip, d at its limit, and a set with d at its limit beep")
        #expect(studio.session == before && model.alert == nil, "a refusal changes nothing and shows no alert")
        await model.close()
    }

    /// C13. The English titles name the content: "Slip Left" fails.
    @Test func slipItemsAreNamedByTheirContent() throws {
        let english = try stringsTable("en")
        #expect(english[L10n.menuEditSlipContentLeft.rawValue] == "Slip Content Left")
        #expect(english[L10n.menuEditSlipContentRight.rawValue] == "Slip Content Right")
        #expect(english[L10n.menuEditRollToPlayhead.rawValue] == "Roll Edit to Playhead")
        #expect(english[L10n.menuEditCloseGaps.rawValue] == "Close Gaps")
    }

    /// C11, C12, C13. During a take the four items are off and the commands change nothing.
    @Test func theItemsAreOffDuringATake() async throws {
        let (model, studio, beeps) = try await opened()
        studio.environment = hal.environment
        let commands: [TimelineCommand] = [.closeGaps, .rollToPlayhead, .slipLeft, .slipRight]
        #expect(commands.allSatisfy(model.isOn), "the items are on while the studio is idle")
        model.timeline.selection = set("a", "b", "c", "e")
        await model.record()
        await hal.feed(seconds: 0.5)
        let before = studio.session
        #expect(commands.allSatisfy { !model.isOn($0) }, "the items are off during the take")
        for command in commands { model.run(command) }
        #expect(studio.session == before && beeps() == 0 && model.alert == nil)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await model.close()
    }
}
