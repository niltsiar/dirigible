import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Multi-clip-selection C11 to C13: the edits on a clip set (decision 0038). The set {A on t1 at
/// 0 ..< 48,000, B on t2 at 96,000 ..< 144,000}; C (not in the set) on t1 at 48,000 ..< 96,000
/// joins A. Files fa, fb, fc are mono and 480,000 frames long; t3 is empty.
struct SelectionClipEditTests {
    let session: Session
    let set: Selection

    init() throws {
        var session = Session(sampleRate: 48_000)
        for id in ["fa", "fb", "fc"] as [FileID] {
            try session.addFile(AudioFile(id: id, path: "\(id).wav", layout: .mono, length: 480_000))
        }
        for n in 1...3 { try session.addTrack(TrackID("t\(n)"), name: "T\(n)", layout: .mono) }
        try session.place(Clip(id: "A", file: "fa", start: 0, offset: 0, length: 48_000), on: "t1")
        try session.place(Clip(id: "C", file: "fc", start: 48_000, offset: 48_000, length: 48_000), on: "t1")
        try session.place(Clip(id: "B", file: "fb", start: 96_000, offset: 0, length: 48_000), on: "t2")
        self.session = session
        set = Self.clips(["A", "B"])
    }

    static func clips(_ ids: Set<ClipID>) -> Selection { ClipSet(ids).map { .clips($0) } ?? .none }

    func ids(_ session: Session?) -> [ClipID] { session?.tracks.flatMap { $0.clips.map(\.id) } ?? [] }

    /// C11a and C12. Control: a Delete of the hull range (0 ..< 144,000 on t1 and t2) removes C.
    @Test func aDeleteOfAClipSetKeepsAnUnselectedClip() throws {
        #expect(ids(try set.deleted(session)) == ["C"])
        #expect(set.marks == nil, "no hull reaches a range edit")
        var hull = session
        try hull.clear(0..<144_000, on: ["t1", "t2"])
        #expect(ids(hull) == [], "the control loses C")
        #expect(try Selection.none.deleted(session) == nil, "no selection, no edit")
    }

    /// C11b: Command-F on each per-track run of joined set clips, as a range that holds the run
    /// whole: a 20 ms crossfade at a join of two set clips, the standard fades at the free edges,
    /// and no fade at a join with a clip that is not in the set.
    @Test func commandFFadesEachRunOfTheSet() throws {
        let fadedAB = try #require(try set.faded(session))
        #expect(fadedAB.clip("A")?.clip.fades == Fades(fadeIn: 24_000, fadeOut: 0), "A joins C at its end")
        #expect(fadedAB.clip("B")?.clip.fades == Fades(fadeIn: 24_000, fadeOut: 24_000))
        #expect(fadedAB.clip("C")?.clip.fades == .zero)
        let fadedABC = try #require(try Self.clips(["A", "B", "C"]).faded(session))
        #expect(fadedABC.clip("A")?.clip.crossfades == Crossfades(start: 0, end: 960))
        #expect(fadedABC.clip("C")?.clip.fades.fadeOut == 24_000)
        #expect(try Self.clips(["gone"]).faded(session) == nil)
    }

    /// C11c: Auto Level and the inspector take exactly the set clips.
    @Test func autoLevelAndTheInspectorTakeTheSetClips() throws {
        var session = session
        try session.setGain(Gain(dB: -6)!, clip: "B")
        #expect(set.clipsToLevel(in: session) == ["A", "B"])
        let inspection = try #require(ClipInspection(selection: set, session: session))
        #expect(inspection.clips == ["A", "B"] && inspection.gain == .mixed)
    }

    /// C11d: Nudge moves the set clips, and the set stays. The start stops at 0.
    @Test func nudgeMovesTheSetAndKeepsIt() throws {
        let right = try #require(set.nudge(by: 480, in: session))
        #expect(right.clips == ["A", "B"] && right.offset == 480 && right.selection == set)
        #expect(set.nudge(by: -480, in: session) == nil, "A is at 0")
    }

    /// C11f, C11g, C11j: Paste and Insert target the first track of the set; Split cuts at the
    /// playhead only the set clips that hold it; Zoom to Selection fits the span of the set.
    @Test func pasteSplitAndZoomTargets() throws {
        let excerpt = try session.excerpt(of: 0..<48_000, on: ["t1", "t2"])
        #expect(set.pasteTracks(for: excerpt, in: session) == ["t1", "t2"])
        #expect(Self.clips(["B"]).pasteTracks(for: excerpt, in: session) == ["t2", "t3"])
        #expect(set.splitPoints(playhead: 24_000, in: session).tracks == ["t1"])
        #expect(set.splitPoints(playhead: 60_000, in: session).tracks == [], "C holds it; C is not in the set")
        #expect(set.span(in: session) == 0..<144_000)
    }

    /// C11i: Show Clips in Finder takes the files of the set clips.
    @Test func showInFinderTakesTheSetFiles() {
        #expect(set.files(in: session) == ["fa", "fb"])
        #expect(Selection.none.files(in: session) == ["fa", "fb", "fc"], "no selection: every clip")
    }

    /// C11k (plan gate 1 item 1): a stale ID of the set never reaches Core.
    @Test func aPartlyStaleSetDeletesAndNudgesTheLiveClips() throws {
        let stale = Self.clips(["A", "B", "gone"])
        #expect(ids(try stale.deleted(session)) == ["C"])
        #expect(stale.nudge(by: 480, in: session)?.clips == ["A", "B"])
    }

    /// C13: I and O set a range at the playhead on the tracks of the set.
    @Test func theKeysLeaveTheClipKind() {
        #expect(set.settingIn(30_000, in: session) == Marks(inPoint: 30_000, tracks: ["t1", "t2"]))
        #expect(set.settingOut(30_000, in: session) == Marks(outPoint: 30_000, tracks: ["t1", "t2"]))
        #expect(Selection.none.settingIn(30_000, in: session) == Marks(inPoint: 30_000, tracks: ["t1", "t2", "t3"]))
    }
}
