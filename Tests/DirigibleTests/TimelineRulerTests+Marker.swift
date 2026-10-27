import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp

/// The current marker on the time ruler (beta fixes criteria M1 to M3, `ui-panel.md` item 2).
extension TimelineRulerTests {
    /// Criterion 11: a click on a flag makes it the current marker and seeks to it. Criterion M1:
    /// the ruler gets the current marker on the next SwiftUI pass.
    @Test func aFlagClickMakesItTheCurrentMarkerAndSeeks() async throws {
        let (model, studio, view, x) = try await openedLanes()
        #expect(view.ruler.current == nil)

        try press(view, x + 1)
        try release(view, x + 2)

        #expect(model.timeline.marker == "m1")
        await until("the flag click seeks") { studio.playhead == 102_400 }
        await until("the ruler shows the current marker") { view.ruler.current == "m1" }
        #expect(studio.session.markers["m1"] == Self.flag, "a click edits nothing")
        await model.close()
    }

    /// `ui-panel.md` item 2: a click on empty ruler time seeks and keeps the current marker, so
    /// the user can click a flag, click the ruler, then choose Move Marker to Playhead.
    @Test func anEmptyRulerClickKeepsTheCurrentMarker() async throws {
        let (model, studio, window, view) = try await lanes()
        model.timeline.marker = "m1"

        try press(view, 600)
        try release(view, 601)

        await until("the click seeks") { studio.playhead == 307_200 }
        #expect(model.timeline.marker == "m1")
        window.close()
        await model.close()
    }

    /// Criterion M2: Add Marker and Next Marker set the current marker of the ruler, and Esc and
    /// Deselect All clear it, with no mouse event. Control: a ruler value set only at a mouse
    /// event fails the Add step.
    @Test func theRulerFollowsTheCurrentMarker() async throws {
        let (model, studio, view, _) = try await openedLanes()
        let window = try #require(view.window)

        model.run(.addMarker)
        let added = try #require(model.timeline.marker)
        await until("Add sets the ruler marker") { view.ruler.current == added }
        #expect(window.makeFirstResponder(view.lanes))
        _ = window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
        await until("Esc clears the ruler marker") { view.ruler.current == nil }
        await studio.perform(.seek(.frame(0)))
        model.run(.nextMarker)
        await until("Next sets the ruler marker") { view.ruler.current == "m1" }
        model.run(.deselectAll)
        await until("Deselect All clears the ruler marker") { view.ruler.current == nil }
        await model.close()
    }

    /// The ruler of `view` drawn into a bitmap.
    func rulerBitmap(_ view: TimelineScrollView) throws -> NSBitmapImageRep {
        let bitmap = try #require(view.ruler.bitmapImageRepForCachingDisplay(in: view.ruler.bounds))
        view.ruler.cacheDisplay(in: view.ruler.bounds, to: bitmap)
        return bitmap
    }

    /// The pixel colors of `bitmap` in the ruler rect `rect`, in sRGB.
    func colors(_ bitmap: NSBitmapImageRep, _ rect: NSRect, of view: TimelineScrollView) -> [NSColor] {
        let scale = Double(bitmap.pixelsWide) / view.ruler.bounds.width
        let columns = Int(rect.minX * scale)..<Int(rect.maxX * scale)
        let rows = Int(rect.minY * scale)..<Int(rect.maxY * scale)
        return rows.flatMap { y in columns.compactMap { bitmap.colorAt(x: $0, y: y)?.usingColorSpace(.sRGB) } }
    }

    /// Criterion M3 (`ui-panel.md` item 1): the current marker draws its name on a pill in the
    /// flag color, black on orange and white on purple, with a 2 pt stem. The other flags do not
    /// change. A marker in the light look shows the dark text; a chapter in the dark look shows the
    /// white text. Control: a draw that ignores `current` gives two equal bitmaps.
    @Test func theCurrentMarkerHasItsOwnLook() async throws {
        let (model, studio, window, view) = try await lanes()
        let chapter = Marker(id: "c2", name: "Part", position: 307_200, kind: .chapter)
        try studio.edit(ripple: false) { s throws(SessionError) in try s.setMarker(chapter) }
        view.update(laneInputs(model, studio))
        let at = { (id: MarkerID) in
            view.ruler.convert(NSPoint(x: id == "m1" ? 200 : 600, y: 0), from: view.lanes).x
        }
        // Inside the pill and the text, right of the flag box: the name starts 8 pt right of the stem.
        let pill = { (id: MarkerID) in NSRect(x: at(id) + 8, y: 11, width: 16, height: 10) }
        let flagColor = { (color: NSColor, flag: NSColor) in
            abs(color.redComponent - flag.redComponent) < 0.1 && abs(color.greenComponent - flag.greenComponent) < 0.1
                && abs(color.blueComponent - flag.blueComponent) < 0.1
        }

        for (id, appearance) in [(MarkerID("m1"), NSAppearance.Name.aqua), ("c2", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            view.ruler.current = nil
            let plain = try rulerBitmap(view)
            view.ruler.current = id
            let current = try rulerBitmap(view)

            // The flag box has the flag color as the ruler draws it.
            let flag = try #require(colors(plain, NSRect(x: at(id) + 3, y: 15, width: 1, height: 1), of: view).first)
            let inPill = colors(current, pill(id), of: view)
            let filled = inPill.filter { flagColor($0, flag) }.count
            #expect(filled * 2 > inPill.count, "\(id): the pill has the flag color in most pixels")
            let text = inPill.contains {
                id == "m1"
                    ? $0.brightnessComponent < 0.25 : $0.brightnessComponent > 0.9 && $0.saturationComponent < 0.1
            }
            #expect(text, "\(id): the name is black on orange, white on purple")
            let stem = NSRect(x: at(id) + 1, y: 0, width: 1, height: 8)
            let stemChanged = colors(current, stem, of: view) != colors(plain, stem, of: view)
            #expect(stemChanged, "\(id): the 2 pt stem")
            let other = NSRect(x: at(id == "m1" ? "c2" : "m1") - 2, y: 0, width: 80, height: 24)
            let otherKept = colors(current, other, of: view) == colors(plain, other, of: view)
            #expect(otherKept, "\(id): the other flag")
        }
        window.close()
        await model.close()
    }

    /// F107 code gate 1 item 2: the outline of a lit flag holds the flag box, the name, and the
    /// pill of the current marker, its stroke does not cross the flag box, and the whole stroke is
    /// inside the 24 pt ruler. The box, name, and pill rects are those of `drawHashMarksAndLabels`.
    @Test(arguments: [0.0, 1.5, 38.0, 240.0]) func theHighlightOutlineHoldsTheFlagInsideTheRuler(nameWidth: Double) {
        let x = 100.0
        let outline = TimelineRuler.highlightRect(at: x, nameWidth: nameWidth, left: 0)
        let half = TimelineRuler.highlightLine / 2
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let box = RulerGeometry.flagReach.upperBound
        let flag = NSRect(x: x, y: 12, width: box, height: box)
        let name = NSRect(x: x + 8, y: 10, width: nameWidth, height: font.ascender - font.descender)
        let pill = NSRect(x: x + 5, y: 9, width: nameWidth + 6, height: 14)
        let ruler = NSRect(x: 0, y: 0, width: 1_000, height: TimelineRuler.thickness)

        #expect(ruler.contains(outline.insetBy(dx: -half, dy: -half)), "the stroke leaves the ruler: \(outline)")
        #expect(outline.insetBy(dx: half, dy: half).contains(flag), "the stroke crosses the flag box: \(outline)")
        #expect(outline.contains(name) && outline.contains(pill), "the outline cuts the name: \(outline)")
    }

    /// F107 code gate 1 item 2, fix check: the ruler draws only right of the left edge of the
    /// lanes, so at that edge the whole stroke stays right of it, and the stroke and the path still
    /// hold the flag box, the name, and the pill. A flag far left of the edge draws no stroke there.
    @Test(arguments: [(0.0, 0.0), (0.0, 1.0), (180.0, 180.0), (180.0, 181.0)])
    func theHighlightOutlineStaysRightOfTheLaneEdge(left: Double, x: Double) {
        let nameWidth = 38.0
        let outline = TimelineRuler.highlightRect(at: x, nameWidth: nameWidth, left: left)
        let half = TimelineRuler.highlightLine / 2
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let box = RulerGeometry.flagReach.upperBound
        let flag = NSRect(x: x, y: 12, width: box, height: box)
        let name = NSRect(x: x + 8, y: 10, width: nameWidth, height: font.ascender - font.descender)
        let pill = NSRect(x: x + 5, y: 9, width: nameWidth + 6, height: 14)
        let drawn = NSRect(x: left, y: 0, width: 1_000, height: TimelineRuler.thickness)

        #expect(drawn.contains(outline.insetBy(dx: -half, dy: -half)), "the stroke leaves the lanes: \(outline)")
        #expect(outline.insetBy(dx: -half, dy: -half).contains(flag), "the outline cuts the flag box: \(outline)")
        #expect(outline.contains(name) && outline.contains(pill), "the outline cuts the name: \(outline)")
        let gone = TimelineRuler.highlightRect(at: left - 100, nameWidth: nameWidth, left: left)
        #expect(gone.width >= 0 && gone.maxX + half <= left, "a flag out of view strokes the edge: \(gone)")
    }
}
