import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The drop cue (run 13c, C9 and C10): the lane tint, the drop line, and the New Track row are
/// layers over the lanes, so a drag update draws no lane pixel (decision 0022).
extension DropTests {
    /// Three 60 pt lanes (180 pt) in a 1200 x 600 pt window of a 120 s session, scrolled right to
    /// frame 480,000 (x 1,000), so the row has room below the lanes.
    func openScrolled() async throws -> (SessionWindow, TimelineScrollView, NSWindow) {
        let (model, _, view) = try await open(tracks: 3, seconds: 120, laneHeight: 60)
        let window = try #require(model.window)
        window.setContentSize(NSSize(width: 1200, height: 600))
        view.scroll(toFrame: 480_000)
        drawNow(window)
        try #require(view.shown.minX == 1_000 && view.shown.minY == 0 && view.shown.maxY > 300, "\(view.shown)")
        return (model, view, window)
    }

    /// C9 a to d: the tint and the line of one file over a lane, the row of a new track and of two
    /// files, each in the lanes in view after a horizontal scroll; ten updates move the line and
    /// draw no lane.
    @Test func theCueFollowsThePointerWithNoLaneDraw() async throws {
        let (model, view, window) = try await openScrolled()
        let (cue, shown) = (view.lanes.drop, view.shown)
        let voice = try wav("Voice.wav")

        let lane = fileDrag([voice], at: NSPoint(x: shown.minX + 100, y: 90), in: view)
        #expect(view.draggingEntered(lane) == .copy)
        #expect(!cue.tint.isHidden && !cue.line.isHidden && cue.row.isHidden && cue.text.isHidden, "a: tint and line")
        #expect(cue.tint.frame == CGRect(x: shown.minX, y: 60, width: shown.width, height: 60), "a: \(cue.tint.frame)")
        #expect(cue.line.frame == CGRect(x: shown.minX + 100, y: 0, width: 1, height: 180), "a: \(cue.line.frame)")
        view.draggingExited(lane)

        let below = fileDrag([voice], at: NSPoint(x: shown.minX + 100, y: 200), in: view)
        #expect(view.draggingEntered(below) == .copy)
        #expect(cue.tint.isHidden && !cue.row.isHidden && !cue.text.isHidden, "b: the row and its text")
        #expect(cue.row.frame == CGRect(x: shown.minX, y: 180, width: shown.width, height: 60), "b: \(cue.row.frame)")
        #expect(cue.text.string as? String == L10n.dropNewTrack.text)
        #expect(cue.text.frame.minX == shown.minX + 12 && shown.contains(cue.text.frame), "b: \(cue.text.frame)")
        #expect(cue.line.frame.minY == 0 && cue.line.frame.maxY == 240, "b: the line goes through the row")
        view.draggingExited(below)

        let two = fileDrag([voice, try wav("B.wav")], at: NSPoint(x: shown.minX + 100, y: 30), in: view)
        #expect(view.draggingEntered(two) == .copy)
        #expect(cue.tint.isHidden && !cue.row.isHidden, "c: the row, no tint")
        #expect(cue.text.string as? String == L10n.dropNewTracks.format(2), "c: the count")
        view.draggingExited(two)

        // The drag reads the one pasteboard at its enter, so a new drag writes the file again.
        _ = view.draggingEntered(fileDrag([voice], at: NSPoint(x: shown.minX + 100, y: 90), in: view))
        drawNow(window)
        let draws = view.lanes.draws
        for n in 1...10 {
            let x = shown.minX + 100 + Double(n) * 7
            let update = fileDrag([voice], at: NSPoint(x: x, y: n % 2 == 0 ? 30 : 90), in: view)
            #expect(view.draggingUpdated(update) == .copy)
            drawNow(window)
            #expect(cue.line.frame.minX == x && cue.tint.frame.minY == (n % 2 == 0 ? 0 : 60), "d: update \(n)")
        }
        #expect(view.lanes.draws == draws, "d: no lane draw: \(view.lanes.draws - draws)")
        view.draggingExited(lane)
        #expect(cue.cueHidden)
        await model.close()
    }

    /// C10: the cue takes the accent and the label color of the palette, and 2 pt lines with
    /// Increase Contrast.
    @Test func theCueTakesThePaletteAndTheContrast() async throws {
        let (model, view, _) = try await openScrolled()
        let cue = view.lanes.drop
        view.lanes.increasesContrast = false
        view.lanes.palette = .light(accent: 0xFF11_2233)
        let voice = try wav("Voice.wav")
        let below = fileDrag([voice], at: NSPoint(x: view.shown.minX + 100, y: 200), in: view)
        let lane = fileDrag([voice], at: NSPoint(x: view.shown.minX + 100, y: 30), in: view)
        _ = view.draggingEntered(below)
        #expect(cue.text.foregroundColor == cgColor(LanePalette.light.label), "the light label color")
        #expect(cue.line.backgroundColor == cgColor(0xFF11_2233) && cue.row.strokeColor == cgColor(0xFF11_2233))

        view.lanes.palette = .dark(accent: 0xFF44_5566)
        _ = view.draggingUpdated(below)
        #expect(cue.text.foregroundColor == cgColor(view.lanes.palette.label), "the dark label color")
        #expect(cue.line.backgroundColor == cgColor(0xFF44_5566), "the new accent")
        #expect(cue.line.frame.width == 1 && cue.row.lineWidth == 1, "1 pt")
        _ = view.draggingUpdated(lane)
        #expect(cue.tint.borderWidth == 1, "a 1 pt border")

        view.lanes.increasesContrast = true
        _ = view.draggingUpdated(lane)
        #expect(cue.tint.borderWidth == 2 && cue.line.frame.width == 2, "Increase Contrast: the border and the line")
        _ = view.draggingUpdated(below)
        #expect(cue.row.lineWidth == 2 && cue.line.frame.width == 2, "Increase Contrast: the row stroke")
        view.draggingExited(below)
        view.lanes.increasesContrast = false
        await model.close()
    }
}
