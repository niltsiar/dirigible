import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Testing

@testable import DirigibleApp

/// Timeline-navigation criteria N9 to N11 in the window: H and back, Zoom Back and Forward, their
/// dim state, smart zoom, and the VoiceOver value change of a stroke. 2 tracks of a 60 s clip.
@Suite(.serialized) @MainActor struct ZoomHistoryWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    func open() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let lanes = try await openLanes(app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
        lanes.3.viewWillMove(toWindow: nil)
        return lanes
    }

    func zoom(_ view: TimelineScrollView) -> Zoom {
        Zoom(scale: TimelineScale(framesPerPoint: view.framesPerPoint), origin: view.origin)
    }

    @Test func anOpenMakesNoHistoryEntry() async throws {
        let (model, _, _, _) = try await open()
        #expect(!model.timeline.canGoBack && !model.timeline.canGoForward, "Zoom Back is dimmed with no step")
        #expect(!model.isOn(.zoomBack) && !model.isOn(.zoomForward), "Zoom Back is dimmed with no step")
        await model.close()
    }

    /// U3: H shows the selection and a second H goes back; with no selection, H fits the session.
    @Test func hZoomsAndGoesBack() async throws {
        let (model, _, _, view) = try await open()
        model.run(.zoomIn)
        let start = zoom(view)
        model.timeline.marks = Marks(inPoint: 480_000, outPoint: 960_000, tracks: ["t1"])
        model.run(.zoomToSelection)
        #expect(abs(view.origin - 456_000) <= view.framesPerPoint)
        model.run(.zoomToSelection)
        #expect(zoom(view) == start, "an unchanged view goes back")
        model.timeline.marks = Marks()
        model.run(.zoomToSelection)
        #expect(
            view.origin == 0 && view.framesPerPoint > start.scale.framesPerPoint, "H with no selection fits the session"
        )
        model.run(.zoomToSelection)
        #expect(zoom(view) == start, "H with no selection goes back")
        #expect(try stringsTable("en")["menu.view.zoom.selection"] == "Zoom to Selection or Session")
        #expect(try stringsTable("es")["menu.view.zoom.selection"] == "Ajustar a la selección o a la sesión")
        await model.close()
    }

    /// N10: Zoom Back after Zoom In (toolbar), Zoom to Session, and an overview edge drag gives the
    /// three views before them in reverse order; Zoom Forward gives them again.
    @Test func zoomBackAndForwardWalkTheViews() async throws {
        let (model, _, _, view) = try await open()
        let strip = try #require(view.overview)
        var views = [zoom(view)]
        model.run(WindowCommand.timeline(.zoomIn))
        views.append(zoom(view))
        model.run(.zoomToSession)
        views.append(zoom(view))
        let frame = strip.viewFrame.frame
        view.overviewEvent(.down(x: Double(frame.maxX), clicks: 1))
        view.overviewEvent(.drag(x: Double(frame.maxX) - 200))
        view.overviewEvent(.drag(x: Double(frame.maxX) - 300))
        view.overviewEvent(.up(x: Double(frame.maxX) - 300))
        let last = zoom(view)
        #expect(model.isOn(.zoomBack) && !model.isOn(.zoomForward))
        for expected in views.reversed() {
            model.run(.zoomBack)
            #expect(zoom(view) == expected)
        }
        #expect(!model.isOn(.zoomBack) && model.isOn(.zoomForward), "Zoom Back is dimmed with no step")
        for expected in views.dropFirst() + [last] {
            model.run(.zoomForward)
            #expect(zoom(view) == expected)
        }
        await model.close()
    }

    /// U11 (N11): at the fit, smart zoom shows the clip under the pointer; again, it fits.
    @Test func smartZoomShowsTheClipUnderThePointer() async throws {
        let (model, studio, _, view) = try await open()
        try studio.edit { s throws(SessionError) in _ = try s.splitClips(at: [960_000], on: ["t1"]) }
        await until(limit: .seconds(10), "the lanes show the split") { view.lanes.inputs?.session == studio.session }
        let fit = zoom(view)
        view.smartZoom(at: NSPoint(x: 100, y: 10))
        #expect(abs(view.origin - 0) <= view.framesPerPoint, "smart zoom shows the clip under the pointer")
        #expect(abs(view.visibleFrames - 1_056_000) <= view.framesPerPoint, "the clip with 5% each side")
        view.smartZoom(at: NSPoint(x: 100, y: 10))
        #expect(zoom(view) == fit)
        await model.close()
    }

    /// U15: VoiceOver gets one value change at the end of a stroke; a mouse wheel burst posts once
    /// after its 0.5 s gap.
    @Test func aStrokePostsOneValueChangeAtItsEnd() async throws {
        let (model, _, _, view) = try await open()
        let strip = try #require(view.overview)
        var posted = strip.valueChanges
        view.navigate(.zoom(by: 0.9, at: 100, stroke: .began))
        for _ in 0..<5 { view.navigate(.zoom(by: 0.9, at: 100, stroke: .changed)) }
        #expect(strip.valueChanges == posted, "no value change during a stroke")
        view.navigate(.zoom(by: 0.9, at: 100, stroke: .ended))
        #expect(strip.valueChanges == posted + 1, "one value change at the end of a stroke")
        posted = strip.valueChanges
        for n in 0..<3 {
            view.navigate(.zoom(by: 0.9, at: 100, stroke: .wheel(time: Double(n) / 10), wheel: Double(n) / 10))
        }
        #expect(strip.valueChanges == posted, "no value change during a wheel burst")
        await until(limit: .seconds(5), "the wheel burst posts after its gap") { strip.valueChanges == posted + 1 }
        await model.close()
    }
}
