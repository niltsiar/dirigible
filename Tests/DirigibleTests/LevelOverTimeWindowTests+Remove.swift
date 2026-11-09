import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// Tools > Remove Level Over Time in the session window (criterion C32 of the leveler run).
extension LevelOverTimeWindowTests {
    /// C32: a ridden clip is on for Remove Level Over Time, and one remove is one undo step that
    /// empties the ride. Redo gives the empty ride again.
    @Test func removeIsOneUndoEntry() async throws {
        let (model, studio, _) = try await open()
        await levelOverTime(model, set("c1", "c2"))
        let ridden = studio.session

        model.timeline.selection = set("c1")
        #expect(model.isOn(.removeLevelOverTime))
        model.run(.removeLevelOverTime)

        #expect(ride("c1", studio).isEmpty && !ride("c2", studio).isEmpty)
        let removed = studio.session
        try studio.undo()
        #expect(studio.session == ridden, "one undo step")
        try studio.redo()
        #expect(studio.session == removed, "redo")
        await model.close()
    }

    /// An enabled Remove acts: a sheet turns it off, and a remove first saves a typed track name,
    /// so Undo takes back the remove only.
    @Test func removeIsOffUnderADialogAndSavesTypedNames() async throws {
        let (model, studio, _) = try await open()
        await levelOverTime(model, set("c1"))
        model.timeline.selection = set("c1")
        model.denoiseDraft = DenoiseDraft(clips: ["c1"], in: studio.session, defaults: nil, region: nil)
        #expect(!model.isOn(.removeLevelOverTime), "the Reduce Noise sheet")
        model.denoiseDraft = nil
        #expect(model.isOn(.removeLevelOverTime), "after the sheet")

        model.drafts["t2"] = "Guest"
        model.run(.removeLevelOverTime)

        #expect(ride("c1", studio).isEmpty && studio.session.track("t2")?.name == "Guest")
        try studio.undo()
        #expect(!ride("c1", studio).isEmpty && studio.session.track("t2")?.name == "Guest", "undo of the remove only")
        await model.close()
    }

    /// C32: with no ridden clip in the selection, the item is off, the command beeps, and no undo
    /// entry is made. Controls: the same selection after a ride is on; a state off during a take.
    @Test func removeIsOffWithNoRide() async throws {
        let (model, studio, _) = try await open()
        var beeps = 0
        model.beep = { beeps += 1 }
        let cases: [(String, Selection)] = [
            ("no selection", .none), ("a clip with no ride", set("c1")),
            ("a track with no ride", .range(Marks(tracks: ["t2"]))),
        ]
        for (name, selection) in cases {
            model.timeline.selection = selection
            #expect(!model.isOn(.removeLevelOverTime), "\(name)")
        }
        model.timeline.selection = set("c1")
        model.run(.removeLevelOverTime)
        #expect(beeps == 1 && !studio.canUndo, "beeps \(beeps)")

        await levelOverTime(model, set("c2"))
        model.timeline.selection = set("c1")
        #expect(!model.isOn(.removeLevelOverTime), "c1 has no ride; only c2 has")
        model.timeline.selection = set("c1", "c2")
        #expect(model.isOn(.removeLevelOverTime), "a set that holds a ridden clip")
        model.timeline.selection = .range(Marks(tracks: ["t2"]))
        #expect(model.isOn(.removeLevelOverTime), "a track with a ridden clip")
        studio.transport = .recording(take: 1)
        #expect(!model.isOn(.removeLevelOverTime), "a take")
        studio.transport = .idle
        await model.close()
    }

    /// C32 (plan gate 6 item 4): with a time range, the remove acts on the range of the selection
    /// on the selected tracks: 0 dB at each frame of the range, the old ride 500 ms outside it.
    /// A ridden clip on an unselected track keeps its ride, and a range past the clip (also past
    /// the 500 ms ramp) leaves the item off.
    @Test func removeUsesTheTimeRange() async throws {
        let (model, studio, _) = try await open()
        await levelOverTime(model, set("c1", "c2"))
        let (c1, c2) = (ride("c1", studio), ride("c2", studio))
        #expect((48_000..<96_000).contains { c1.gain(at: Frames($0)) != 0 }, "the fixture ride has a level there")

        model.timeline.selection = .range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))
        #expect(model.isOn(.removeLevelOverTime))
        model.run(.removeLevelOverTime)

        let after = ride("c1", studio)
        for frame in stride(from: 48_000, to: 96_000, by: 4_800) {
            #expect(after.gain(at: Frames(frame)) == 0, "frame \(frame)")
        }
        #expect(after != c1 && !after.isEmpty, "the ride outside the range stays")
        #expect(after.gain(at: 0) == c1.gain(at: 0) && after.gain(at: 130_000) == c1.gain(at: 130_000))
        #expect(ride("c2", studio) == c2, "the other track keeps its ride")
        try studio.undo()
        #expect(ride("c1", studio) == c1, "one undo step")

        model.timeline.selection = .range(Marks(inPoint: 1_000_000, outPoint: 1_001_000, tracks: ["t1"]))
        #expect(!model.isOn(.removeLevelOverTime), "a range past the clip")
        await model.close()
    }

    /// The 1.5 s crossfade after the ridden part c1 (0..1 s) sounds to 1.75 s, past the 500 ms
    /// ramp. A range from 1.6 s meets c1 only in that half: the item is on, and c1 plays 0 dB there.
    @Test func removeReachesACrossfadeHalfInTheRange() async throws {
        let (model, studio, _) = try await open()
        try studio.edit(ripple: false, agent: nil) { session throws(SessionError) in
            try session.splitClips(at: [48_000], on: ["t1"])
            try session.setGain(Gain(dB: 1)!, clip: "c1@48000")
            try session.setCrossfades(["c1": 72_000])
        }
        await levelOverTime(model, set("c1"))
        let half = stride(from: 76_800, to: 84_000, by: 480).map { Frames($0) }
        #expect(half.contains { ride("c1", studio).gain(at: $0) != 0 }, "the fixture ride has a level there")

        model.timeline.selection = .range(Marks(inPoint: 76_800, outPoint: 120_000, tracks: ["t1"]))
        #expect(model.isOn(.removeLevelOverTime))
        model.run(.removeLevelOverTime)

        let after = ride("c1", studio)
        #expect(half.allSatisfy { after.gain(at: $0) == 0 }, "c1 keeps its ride in the range")
        await model.close()
    }
}
