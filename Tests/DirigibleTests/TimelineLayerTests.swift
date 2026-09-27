import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import IOSurface
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The lanes as one layer of IOSurfaces written in place (decision 0022, timeline-layer criteria
/// 1, 4, 5, and 7). The fixture: tracks of 200 s of one file with a long name, split into clips of
/// 120 pt at 512 frames per point, with peaks. The lanes in view are 1440 x 376 pt.
@Suite(.serialized) @MainActor struct TimelineLayerTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    static let frames = 9_600_000
    static let peaks: [FileID: PeakState] = ["f1": .ready(randomPeaks(frames: frames))]

    /// The session of the fixture: `tracks` tracks, each with clips of 61,440 frames (120 pt). Track
    /// n splits 15 pt later than track n - 1, so no two lanes show the same pixels: a surface read
    /// at the rows of another lane shows other pixels.
    static func session(tracks: Int) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(
            AudioFile(
                id: "f1", path: "a-long-take-name-for-the-guest-interview.wav", layout: .mono, length: Frames(frames)))
        let ids = (1...tracks).map { TrackID("t\($0)") }
        for (n, track) in ids.enumerated() {
            try session.addTrack(track, name: "T\(n + 1)", layout: .mono)
            try session.place(
                Clip(id: ClipID("c\(n + 1)"), file: "f1", start: 0, offset: 0, length: Frames(frames)), on: track)
        }
        for (n, track) in ids.enumerated() {
            _ = try session.splitClips(
                at: stride(from: 61_440 + n * 7_680, to: frames, by: 61_440).map { Frames($0) }, on: [track])
        }
        return session
    }

    /// The lanes of the fixture in a window, at 512 frames per point, drawn once. The Studio gets
    /// the session and a save that does not write, as in `MouseEventBenchmark`.
    func lanes(tracks: Int = 6, onScreen: Bool = false) async throws -> (
        SessionWindow, Studio, NSWindow, TimelineScrollView
    ) {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 1, seconds: 1), app: app)
        let url = studio.url
        studio.environment.saveSession = { _, _ in url }
        let session = try Self.session(tracks: tracks)
        try studio.edit { s throws(SessionError) in s = session }
        let (window, view) = standaloneLanes(model, studio, onScreen: onScreen)
        view.update(inputs(model, studio))
        drawNow(window)
        return (model, studio, window, view)
    }

    /// The inputs of SwiftUI: the Studio session and the Marks of the window, with the peaks.
    func inputs(_ model: SessionWindow, _ studio: Studio, laneHeight: Double = 100) -> LaneInputs {
        var inputs = laneInputs(model, studio, marks: model.timeline.marks)
        inputs.peaks = Self.peaks
        inputs.laneHeight = laneHeight
        inputs.scale = model.timeline.scale
        return inputs
    }

    /// Criterion 4: no update writes a surface that the window server uses. 4 updates back to back,
    /// then 10 pairs of updates 1 ms apart every 20 ms, in a window on screen. Then the surfaces that
    /// are not the layer contents are held on screen, and 3 more updates come. No write reaches a
    /// surface in use or the layer contents, and the last input shows.
    @Test func anUpdateNeverWritesASurfaceInUse() async throws {
        let (model, studio, window, view) = try await lanes(onScreen: true)
        var n = 0
        func update() {
            n += 1
            model.timeline.marks = Marks(
                inPoint: Frames(n * 5_120), outPoint: Frames(n * 5_120 + 51_200), tracks: ["t2"])
            view.update(inputs(model, studio))
            drawNow(window)
        }
        for _ in 0..<4 { update() }
        for _ in 0..<10 {
            update()
            try await Task.sleep(for: .milliseconds(1))
            update()
            try await Task.sleep(for: .milliseconds(20))
        }
        let held = try await Self.holdOnScreen(view, window)
        for _ in 0..<3 { update() }

        let surfaces = view.lanes.surfaces
        #expect(surfaces.writesInUse == 0, "writesInUse \(surfaces.writesInUse)")
        #expect(surfaces.writesOfFront == 0, "writesOfFront \(surfaces.writesOfFront)")
        let wrong = try Self.wrongPixels(view)
        #expect(
            wrong.count == 0,
            "the last input shows: \(wrong.count) pixels differ, the first \(String(describing: wrong.first))")
        for layer in held { layer.removeFromSuperlayer() }
        window.close()
        await model.close()
    }

    /// Criterion 7 and the slot count: after warm-up, 10 pairs of updates 1 ms apart every 20 ms
    /// make no new surface, and the lanes hold 4: the others cover the frames that the window server
    /// still shows.
    @Test func twoUpdatesPerFrameReuseTheirSurfaces() async throws {
        let (model, studio, window, view) = try await lanes(onScreen: true)
        var n = 0
        func update() {
            n += 1
            model.timeline.marks = Marks(
                inPoint: Frames(n * 5_120), outPoint: Frames(n * 5_120 + 51_200), tracks: ["t2"])
            view.update(inputs(model, studio))
            drawNow(window)
        }
        for _ in 0..<3 { update() }
        try await Task.sleep(for: .milliseconds(40))
        let made = view.lanes.surfaces.made

        for _ in 0..<10 {
            update()
            try await Task.sleep(for: .milliseconds(1))
            update()
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(view.lanes.surfaces.made - made == 0, "new surfaces: \(view.lanes.surfaces.made - made)")
        #expect(view.lanes.surfaces.count == 4)
        window.close()
        await model.close()
    }

    /// Criterion 4, the front check: with no window server (a layer in no window), `isInUse` is
    /// false for every surface, so only the front check keeps a write from the layer contents.
    @Test func aWindowlessSurfacesNeverWriteTheirFront() throws {
        let surfaces = LaneSurfaces()
        let rect = CGRect(x: 0, y: 0, width: 100, height: 200)
        let window = try #require(LaneWindow(view: rect, bounds: rect, laneHeight: 100, lanes: 2, scale: 2))

        for n in 0..<6 {
            let drawn = surfaces.show(window, changed: window.pixels) { region in
                region.fill(UInt32(n), columns: region.rect.columns, rows: region.rect.rows)
            }
            #expect(drawn == .drawn(window.pixels))
        }

        #expect(surfaces.writesOfFront == 0, "writesOfFront \(surfaces.writesOfFront)")
        #expect(surfaces.pixel(column: 0, row: 0) == 5)
        #expect(surfaces.count == 4)
    }

    /// Code gate 1 item 1: a refused surface keeps the change. The window server uses every surface
    /// but the layer contents, so the next update needs a new surface, and the allocation fails.
    /// The update draws nothing, and the next display after the allocation works shows the change.
    @Test func aRefusedSurfaceKeepsTheChangeForTheNextDisplay() async throws {
        let (model, studio, window, view) = try await lanes(onScreen: true)
        for n in 1...4 {
            model.timeline.marks = Marks(inPoint: Frames(n * 5_120), outPoint: Frames(n * 5_120 + 51_200))
            view.update(inputs(model, studio))
            drawNow(window)
        }
        let held = try await Self.holdOnScreen(view, window)
        let surfaces = view.lanes.surfaces
        let draws = view.lanes.draws

        surfaces.refusesNewSurfaces = true
        model.timeline.marks = Marks(inPoint: 204_800, outPoint: 256_000, tracks: ["t2"])
        view.update(inputs(model, studio))
        drawNow(window)
        #expect(view.lanes.draws == draws, "the refused update draws nothing")
        surfaces.refusesNewSurfaces = false
        for layer in held { layer.removeFromSuperlayer() }
        await until(limit: .seconds(5), "the next display draws the change") {
            drawNow(window)
            return view.lanes.draws > draws
        }

        let wrong = try Self.wrongPixels(view)
        let first = String(describing: wrong.first)
        #expect(wrong.count == 0, "the change shows: \(wrong.count) pixels differ, the first \(first)")
        window.close()
        await model.close()
    }

    /// Criterion 5: each surface is tagged sRGB (probe P2: an untagged surface showed R 196 against
    /// 200 for the clip color).
    @Test func eachSurfaceIsTaggedSRGB() async throws {
        let (model, _, window, view) = try await lanes()
        for _ in 0..<4 {
            view.scroll(toFrame: view.origin + 20 * view.framesPerPoint)
            drawNow(window)
        }
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB)?.copyPropertyList())

        let surfaces = view.lanes.surfaces.surfaces
        #expect(surfaces.count == 4)
        for surface in surfaces {
            let tag = IOSurfaceCopyValue(surface, kIOSurfaceColorSpace)
            #expect(tag.map { CFEqual($0, srgb) } == true, "\(String(describing: tag))")
        }
        window.close()
        await model.close()
    }

    /// Criterion 7: the lanes hold 4 surfaces or fewer, each of the capacity of the current view,
    /// after each of 8 page turns, 60 drag events, 40 marker adds, 40 undo steps, 5 window resizes,
    /// and updates while the window server uses the other surfaces.
    @Test func theSurfacesStayBounded() async throws {
        let (model, studio, window, view) = try await lanes(tracks: 2, onScreen: true)
        var failures: [String] = []
        func check(_ step: String) {
            let surfaces = view.lanes.surfaces
            guard let capacity = surfaces.shown?.capacity else { return failures.append("\(step): no window") }
            let sizes = surfaces.surfaces.map { "\($0.width)x\($0.height)" }
            let bytes = surfaces.surfaces.first { $0.width == capacity.columns }?.allocationSize ?? 0
            if surfaces.count > 4 || sizes.contains(where: { $0 != "\(capacity.columns)x\(capacity.rows)" })
                || surfaces.bytes > 4 * bytes
            {
                failures.append("\(step): \(sizes), capacity \(capacity.columns)x\(capacity.rows)")
            }
        }
        view.tick(playhead: 0, playback: .playing(Shuttle(direction: .forward, rate: .one)))
        for turn in 0..<8 {
            view.tick(
                playhead: view.origin + 0.95 * view.visibleFrames,
                playback: .playing(Shuttle(direction: .forward, rate: .one)))
            drawNow(window)
            check("turn \(turn)")
            await Task.yield()
        }
        view.scroll(toFrame: 0)
        drawNow(window)
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 150, y: 10), in: view))
        for n in 1...60 {
            view.lanes.mouseDragged(
                with: try mouse(.leftMouseDragged, NSPoint(x: 150 + Double(3 + n), y: 10), in: view))
            drawNow(window)
            check("drag \(n)")
            await Task.yield()
        }
        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 213, y: 10), in: view))
        for n in 0..<40 {
            model.addMarker(.marker, at: Frames(n * 18_000))
            view.update(inputs(model, studio))
            drawNow(window)
            check("marker \(n)")
            await Task.yield()
        }
        for n in 0..<40 {
            model.undo()
            view.update(inputs(model, studio))
            drawNow(window)
            check("undo \(n)")
            await Task.yield()
        }
        // Each resize makes the view smaller, so a kept surface is larger than the new capacity. The
        // wait lets the window server free the other surfaces first, so the pick can keep one.
        for n in 0..<5 {
            try await Task.sleep(for: .milliseconds(40))
            window.setContentSize(NSSize(width: window.frame.width - 40, height: window.frame.height - 20))
            view.frame = try #require(window.contentView).bounds
            drawNow(window)
            check("resize \(n)")
            await Task.yield()
        }
        // Four scrolls fill the slots, then the window server uses every surface but the contents.
        for n in 0..<4 {
            view.scroll(toFrame: view.origin + 20 * view.framesPerPoint)
            drawNow(window)
            check("fill \(n)")
        }
        let held = try await Self.holdOnScreen(view, window)
        #expect(held.count == 3, "the held surfaces")
        for n in 0..<3 {
            view.scroll(toFrame: view.origin + 20 * view.framesPerPoint)
            drawNow(window)
            check("held \(n)")
        }

        #expect(failures.isEmpty, "\(failures.prefix(5))")
        #expect(studio.session.markers.isEmpty, "each undo takes a marker back")
        for layer in held { layer.removeFromSuperlayer() }
        window.close()
        await model.close()
    }

    /// Slice 2 of the timeline-layer run (buffer age): after warm-up, each of 20 drag events copies
    /// from the front only the rects that the 3 commits after its surface drew (the 3 events before
    /// it), never the lanes in view. With 4 slots the pick is 4 commits old.
    @Test func aDragEventCopiesOnlyTheRectsOfTheLaterCommits() async throws {
        let (model, studio, window, view) = try await lanes()
        model.timeline.scale = TimelineScale(framesPerPoint: 512)
        view.update(inputs(model, studio))
        drawNow(window)
        // A clip of 120 pt at x 120 to 240 on lane 1; the upper part moves it.
        let down = NSPoint(x: 150, y: 10)
        view.lanes.mouseDown(with: try mouse(.leftMouseDown, down, in: view))
        var drawn: [PixelRect] = []
        var failures: [String] = []

        for n in 1...24 {
            let draws = view.lanes.draws
            view.lanes.mouseDragged(
                with: try mouse(.leftMouseDragged, NSPoint(x: down.x + Double(3 + n), y: down.y), in: view))
            drawNow(window)
            try #require(view.lanes.draws == draws + 1, "event \(n) draws once")
            let surfaces = view.lanes.surfaces
            let shown = try #require(surfaces.shown)
            let rect = shown.pixels(of: view.lanes.drawnRect)
            try #require(rect.columns.count < shown.pixels.columns.count / 2, "event \(n) draws its columns: \(rect)")
            if n > 4, surfaces.lastCopied != Array(drawn.suffix(3)) {
                failures.append("event \(n): copied \(surfaces.lastCopied), drew before \(drawn.suffix(3))")
            }
            drawn.append(rect)
            await Task.yield()
        }

        view.lanes.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: down.x + 27, y: down.y), in: view))
        #expect(failures.isEmpty, "\(failures.count) events: \(failures.prefix(3))")
        window.close()
        await model.close()
    }

    /// Criterion 7 (plan gate 1 item 2): after 3 warm-up scrolls, 40 horizontal scrolls of 0.37 pt
    /// and a vertical scroll across two lane edges make no new surface, and the window in view
    /// always fits the capacity.
    @Test func aScrollKeepsItsSurfaces() async throws {
        let (model, _, window, view) = try await lanes(tracks: 8)
        for _ in 0..<3 {
            view.scroll(toFrame: view.origin + 20 * view.framesPerPoint)
            drawNow(window)
        }
        let made = view.lanes.surfaces.made
        var overflows: [String] = []
        func fits() {
            guard let shown = view.lanes.surfaces.shown else { return overflows.append("no window") }
            let (pixels, capacity) = (shown.pixels, shown.capacity)
            if pixels.columns.count > capacity.columns || pixels.rows.count > capacity.rows {
                overflows.append("\(pixels.columns.count)x\(pixels.rows.count) in \(capacity.columns)x\(capacity.rows)")
            }
        }

        for _ in 0..<40 {
            view.scroll(toFrame: view.origin + 0.37 * view.framesPerPoint)
            drawNow(window)
            fits()
        }
        for step in 1...8 {
            view.contentView.scroll(to: NSPoint(x: view.contentView.bounds.minX, y: Double(step) * 30 - 24))
            view.reflectScrolledClipView(view.contentView)
            drawNow(window)
            fits()
        }

        #expect(overflows.isEmpty, "the window fits the capacity: \(overflows.prefix(3))")
        #expect(view.shown.minY >= 200, "\(view.shown)")
        #expect(view.lanes.surfaces.made == made, "new surfaces: \(view.lanes.surfaces.made - made)")
        window.close()
        await model.close()
    }

    /// Criterion 7: a window at a fraction of a pixel in both axes fits the capacity. The clip
    /// view scrolls by whole pixels, so only a view rect of another caller has such an origin.
    @Test func aFractionalWindowFitsTheCapacity() throws {
        let bounds = CGRect(x: 0, y: 0, width: 20_000, height: 800)
        for (x, y) in [(1333.37, 37.3), (0.2, 99.9), (18_000.49, 250.01)] {
            let window = try #require(
                LaneWindow(
                    view: CGRect(x: x, y: y, width: 1440, height: 376), bounds: bounds, laneHeight: 100, lanes: 8,
                    scale: 2))
            #expect(window.pixels.columns.count <= window.capacity.columns, "columns at \(x)")
            #expect(window.pixels.rows.count <= window.capacity.rows, "rows at \(y)")
        }
    }

    /// The layer shows the used part of the contents with no scale: its frame is whole pixels and
    /// holds the lanes in view, and `contentsRect` times the capacity is the window in pixels. The
    /// playhead is over it. The origin is 1333.37 pt, a fraction of a pixel.
    @Test func theLayerShowsTheUsedPartUnscaled() async throws {
        let (model, _, window, view) = try await lanes()
        view.scroll(toFrame: 1333.37 * view.framesPerPoint)
        drawNow(window)

        let lanes = view.lanes
        let layer = lanes.surfaces.layer
        let shown = try #require(lanes.surfaces.shown)
        let scale = shown.scale
        let frame = layer.frame
        for value in [frame.minX, frame.minY, frame.width, frame.height] {
            #expect((value * scale).rounded() == value * scale, "\(frame)")
        }
        #expect(frame.contains(view.shown.intersection(lanes.bounds)), "\(frame) holds \(view.shown)")
        let contents = layer.contentsRect
        #expect(contents.origin == .zero)
        #expect(abs(contents.width * Double(shown.capacity.columns) - Double(shown.pixels.columns.count)) < 1e-9)
        #expect(abs(contents.height * Double(shown.capacity.rows) - Double(shown.pixels.rows.count)) < 1e-9)
        #expect(frame.width * scale == Double(shown.pixels.columns.count))
        #expect(lanes.playhead.zPosition > layer.zPosition)
        window.close()
        await model.close()
    }
}
