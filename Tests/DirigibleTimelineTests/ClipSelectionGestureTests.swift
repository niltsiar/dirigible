import DirigibleCore
import Testing

@testable import DirigibleTimeline

/// Multi-clip-selection C2 to C4: Command-click on the upper part of a clip adds it to the clip
/// set or removes it (decision 0038). The fixture of `GroupGesture`.
struct ClipSelectionGestureTests {
    var g: GroupGesture

    init() throws { g = try GroupGesture() }

    /// The one selection effect of `effects`, or nil.
    static func selection(_ effects: [GestureEffect]) -> Selection? {
        guard effects.count == 1, case .selection(let selection) = effects[0] else { return nil }
        return selection
    }

    /// C2. Control: the Command range press of today gives a track toggle, not a clip set.
    @Test mutating func aCommandClickAddsAndRemovesAClip() throws {
        g.selection = try #require(Self.selection(g.click(150, 10)))
        #expect(g.selection == GroupGesture.clips(["A"]))
        g.selection = try #require(Self.selection(g.click(150, 70, command: true)))
        #expect(g.selection == GroupGesture.clips(["A", "B"]))
        g.selection = try #require(Self.selection(g.click(150, 70, command: true)))
        #expect(g.selection == GroupGesture.clips(["A"]))
        #expect(Self.selection(g.click(150, 10, command: true)) == Selection.none, "the last clip goes")
    }

    @Test mutating func aDragOfASelectedClipMovesTheSet() throws {
        g.selection = GroupGesture.clips(["A", "B"])
        let result = try #require(g.committed(g.move(from: (150, 70), to: (200, 70))))
        #expect(GroupGesture.places(result.session)["A"] == "t1@72000")
        #expect(GroupGesture.places(result.session)["B"] == "t2@72000")
    }

    /// C3: one case per start state.
    @Test mutating func aCommandClickInEachStartState() throws {
        let b = GroupGesture.clips(["B"])
        #expect(Self.selection(g.click(150, 70, command: true)) == b, "(a) no selection")
        g.selection = .range(Marks(inPoint: 48_000, outPoint: 96_000, tracks: ["t1"]))
        #expect(Self.selection(g.click(150, 70, command: true)) == GroupGesture.clips(["A", "B"]), "(b)")
        g.selection = .range(Marks(inPoint: 50_000, outPoint: 90_000, tracks: ["t1"]))
        #expect(Self.selection(g.click(150, 70, command: true)) == b, "(c) a range that holds no clip whole")
        g.selection = GroupGesture.clips(["A"])
        #expect(Self.selection(g.click(150, 70, command: true)) == GroupGesture.clips(["A", "B"]), "(d)")
        g.selection = .none
        #expect(Self.selection(g.click(150, 110, command: true)) == .range(Marks(tracks: ["t2"])), "(e) lower part")
        #expect(Self.selection(g.click(700, 10, command: true)) == .range(Marks(tracks: ["t1"])), "(e) a gap")
        g.canEdit = false
        #expect(Self.selection(g.click(150, 70, command: true)) == b, "(f) during a take")
        g.canEdit = true
        g.selection = GroupGesture.clips(["A"])
        #expect(g.click(700, 10, command: true) == [], "(g) a gap keeps the clip set")
    }

    /// C4: a click with no drag on a clip of the set selects that clip alone, as a one-clip set.
    @Test mutating func aClickOnASelectedClipSelectsOnlyThatClip() {
        g.selection = GroupGesture.clips(["A", "B"])
        #expect(g.click(150, 10) == [.clip("A")])
    }

    /// C17: from the set of A (t1, 1 s to 2 s) and D (t3, 5 s to 6 s) with the playhead at 0.5 s,
    /// a Shift-click at 6 s in a gap of t2 gives 0.5 s to 6 s on t1, t2, and t3.
    @Test mutating func aShiftClickFromAClipSetExtendsOnItsTracks() {
        g.selection = GroupGesture.clips(["A", "D"])
        let context = GestureContext(
            session: g.session, selection: g.selection, playhead: 24_000, geometry: Fixture.geometry, canEdit: true,
            canRipple: true)
        _ = g.gesture.handle(.down(.lanes(x: 600, y: 90), shift: true, command: false), context)

        let effects = g.gesture.handle(.up(.lanes(x: 600, y: 90)), context)

        #expect(effects == [.marks(Marks(inPoint: 24_000, outPoint: 288_000, tracks: ["t1", "t2", "t3"]))])
    }

    /// C17: from the set of A (t1, 1 s to 2 s), a Shift-drag on t1 from 5 s to 6 s gives 1 s to 6 s
    /// on t1: the hull of the set span and the drag range.
    @Test mutating func aShiftDragFromAClipSetExtendsItsSpan() {
        g.selection = GroupGesture.clips(["A"])
        _ = g.gesture.handle(.down(.lanes(x: 500, y: 10), shift: true, command: false), g.context)

        let effects = g.gesture.handle(.drag(.lanes(x: 600, y: 10)), g.context)

        #expect(effects == [.marks(Marks(inPoint: 48_000, outPoint: 288_000, tracks: ["t1"]))])
    }

    /// A Command-drag from a clip stays a range drag (decision 0020).
    @Test mutating func aCommandDragFromAClipIsARangeDrag() {
        _ = g.down(150, 10, command: true)
        #expect(g.drag(200, 10) == [.marks(Marks(inPoint: 72_000, outPoint: 96_000, tracks: ["t1"]))])
        #expect(g.gesture.drawn(g.session) == g.session)
    }
}
