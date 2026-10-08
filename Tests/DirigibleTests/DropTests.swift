import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// A Finder drop of audio files on the lanes of a real session window (run 13c, C1 to C8 and C15).
/// A fake `NSDraggingInfo` gives the drag; the Finder drag itself is manual check M1.
@Suite(.serialized) @MainActor struct DropTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws { folder = try TemporaryFolder() }

    /// A WAV of 1 s of silence at 48 kHz in the test folder.
    func wav(_ name: String, channels: Int = 1) throws -> URL {
        let url = folder.url.appending(path: name)
        try writeSilentWAV(url, channels: channels)
        return url
    }

    /// A key window with the lanes of tracks t1 to t<tracks> (T1 to T<tracks>, a clip from 0 each)
    /// at 480 frames per point and `laneHeight` pt lanes, at origin 0.
    func open(tracks: Int = 2, seconds: Int = 2, laneHeight: Double = 60) async throws
        -> (SessionWindow, Studio, TimelineScrollView)
    {
        let package = try await timelinePackage(in: folder.url, tracks: tracks, seconds: seconds)
        let (model, studio, _, view) = try await openLanes(app, package)
        studio.environment.playerOutput = .offline
        await until("the first view is fitted") { view.fitted }
        model.timeline.scale = TimelineScale(framesPerPoint: 480)
        model.timeline.laneHeight = .fixed(laneHeight)
        await until("the lanes take the zoom and the height") {
            view.framesPerPoint == 480 && view.lanes.inputs?.laneHeight == laneHeight
        }
        view.scroll(toFrame: 0)
        return (model, studio, view)
    }

    /// Enters, drops, and ends a drag of `urls` at the lane point `point`, as AppKit does after an
    /// accepted drop, then waits for the import. False when the drag or the drop is refused.
    func drop(_ urls: [URL], at point: NSPoint, in view: TimelineScrollView, _ model: SessionWindow) async -> Bool {
        let drag = fileDrag(urls, at: point, in: view)
        guard view.draggingEntered(drag) == .copy, view.performDragOperation(drag) else { return false }
        view.concludeDragOperation(drag)
        view.draggingEnded(drag)
        await until("the import ends") { model.importJob == nil }
        return true
    }

    /// C1: a text file gets no operation; a WAV gets copy.
    @Test func aTextFileGetsNoOperation() async throws {
        let (model, _, view) = try await open()
        let text = folder.url.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)
        let point = NSPoint(x: 100, y: 30)

        let refused = fileDrag([text], at: point, in: view)
        #expect(view.draggingEntered(refused) == [], "the enter of a text file")
        #expect(view.draggingUpdated(refused) == [], "an update of a text file")
        view.draggingExited(refused)

        let accepted = fileDrag([try wav("Voice.wav")], at: point, in: view)
        #expect(view.draggingEntered(accepted) == .copy, "a WAV gets copy")
        view.draggingExited(accepted)
        await model.close()
    }

    /// C1: a mixed drag takes only its audio file.
    @Test func aMixedDragCountsOnlyTheAudioFile() async throws {
        let (model, _, view) = try await open()
        let text = folder.url.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)

        let drag = fileDrag([text, try wav("Voice.wav")], at: NSPoint(x: 100, y: 30), in: view)

        #expect(view.draggingEntered(drag) == .copy)
        #expect(drag.numberOfValidItemsForDrop == 1 && view.lanes.drop.urls.map(\.lastPathComponent) == ["Voice.wav"])
        view.draggingExited(drag)
        await model.close()
    }

    /// C2 a, b, d, and e: no operation during an import or a take; an import that starts after the
    /// enter refuses the next update; a refused drop imports nothing and holds no file.
    @Test func aDragWhileBusyGetsNoOperation() async throws {
        let (model, studio, view) = try await open()
        let voice = try wav("Voice.wav")
        let point = NSPoint(x: 100, y: 30)
        let drag = fileDrag([voice], at: point, in: view)
        #expect(view.draggingEntered(drag) == .copy, "an idle window gets copy")

        model.importJob = ImportJob()
        #expect(view.draggingUpdated(drag) == [], "d: an import that starts after the enter")
        let before = studio.session
        #expect(!view.performDragOperation(drag), "e: a drop during an import")
        #expect(view.lanes.drop.urls.isEmpty, "e: a refused drop holds no file")
        view.draggingEnded(drag)
        #expect(studio.session == before, "e: a refused drop imports nothing")

        let busy = fileDrag([voice], at: point, in: view)
        #expect(view.draggingEntered(busy) == [], "a: a drag during an import")
        view.draggingExited(busy)
        model.importJob = nil

        studio.transport = .recording(take: 1)
        let take = fileDrag([voice], at: point, in: view)
        #expect(view.draggingEntered(take) == [], "b: a drag during a take")
        view.draggingExited(take)
        studio.transport = .idle
        await model.close()
    }

    /// C3: an exit, the end of a drag, a refused drop, and a drop leave no file held.
    @Test func anExitClearsTheCue() async throws {
        let (model, studio, view) = try await open()
        let voice = try wav("Voice.wav")
        let drag = fileDrag([voice], at: NSPoint(x: 100, y: 30), in: view)
        let headers = fileDrag([voice], at: NSPoint(x: view.shown.minX - 20, y: 30), in: view)

        _ = view.draggingEntered(drag)
        #expect(!view.lanes.drop.urls.isEmpty, "the enter holds the file")
        view.draggingExited(drag)
        #expect(view.lanes.drop.urls.isEmpty, "after an exit")

        _ = view.draggingEntered(drag)
        view.draggingEnded(drag)
        #expect(view.lanes.drop.urls.isEmpty, "after the end of the drag")

        _ = view.draggingEntered(drag)
        #expect(!view.performDragOperation(headers), "a drop over the headers is refused")
        #expect(view.lanes.drop.urls.isEmpty, "after a refused drop")

        _ = view.draggingEntered(drag)
        #expect(view.performDragOperation(drag))
        view.concludeDragOperation(drag)
        #expect(view.lanes.drop.urls.isEmpty, "after a drop")
        await until("the import ends") { model.importJob == nil }
        #expect(studio.session.clip("Voice") != nil)
        await model.close()
    }

    /// C4 a and C15 a: one file on lane 1 goes on t2 at the frame under the pointer, is selected,
    /// and one Undo removes it. The drop commits the name typed in a header first.
    @Test func aDropOnALaneImportsOnThatTrackAtThePointer() async throws {
        let (model, studio, view) = try await open()
        model.drafts["t1"] = "Typed"

        #expect(await drop([try wav("Voice.wav")], at: NSPoint(x: 100, y: 90), in: view, model))

        let placed = studio.session.clip("Voice")
        #expect(placed?.track == "t2" && placed?.clip.start == 48_000, "the clip is on t2 at 48,000")
        #expect(studio.session.tracks.count == 2, "no new track")
        #expect(model.timeline.selection == ClipSet(["Voice"]).map { .clips($0) }, "the new clip is selected")
        #expect(model.alert == nil)
        #expect(studio.session.track("t1")?.name == "Typed", "C15 a: the typed name is saved")
        #expect(studio.session.track("t2")?.name == "T2", "a track with no draft keeps its name")
        model.undo()
        #expect(studio.session.clip("Voice") == nil, "one Undo removes the clip")
        await model.close()
    }

    /// C4 b: at a scrolled origin in a long session, the clip is under the pointer.
    @Test func aDropAtAScrolledOriginLandsUnderThePointer() async throws {
        let (model, studio, view) = try await open(tracks: 10, seconds: 120, laneHeight: 100)
        model.window?.setContentSize(NSSize(width: 1200, height: 600))
        view.scroll(toFrame: 4_320_000)
        view.contentView.scroll(
            to: NSPoint(x: view.contentView.bounds.minX, y: 400 - view.contentView.contentInsets.top))
        view.reflectScrolledClipView(view.contentView)
        try #require(view.shown.minX == 9_000 && view.shown.minY == 400, "\(view.shown)")

        #expect(await drop([try wav("Voice.wav")], at: NSPoint(x: 9_100, y: 450), in: view, model))

        let placed = studio.session.clip("Voice")
        #expect(placed?.track == "t5" && placed?.clip.start == 4_368_000, "the clip is on t5 under the pointer")
        await model.close()
    }

    /// C5: one file below the last lane makes a new last track named after the file.
    @Test func aDropBelowTheLastLaneMakesANewTrack() async throws {
        let (model, studio, view) = try await open()
        try #require(view.shown.maxY > 200, "room below the 120 pt of lanes: \(view.shown)")

        #expect(await drop([try wav("Voice.wav")], at: NSPoint(x: 100, y: 150), in: view, model))

        let last = try #require(studio.session.tracks.last)
        #expect(studio.session.tracks.count == 3 && last.name == "Voice", "a new last track")
        let placed = studio.session.clip("Voice")
        #expect(placed?.track == last.id && placed?.clip.start == 48_000, "the clip is on the new track")
        await model.close()
    }

    /// C6 a: two files on lane 0 make one new track each at the drop frame.
    @Test func aDropOfTwoFilesMakesOneTrackPerFile() async throws {
        let (model, studio, view) = try await open()
        let t1 = studio.session.track("t1")

        #expect(await drop([try wav("A.wav"), try wav("B.wav")], at: NSPoint(x: 100, y: 30), in: view, model))

        #expect(studio.session.tracks.map(\.name) == ["T1", "T2", "A", "B"], "one new track per file")
        let clips = ["A", "B"].map { studio.session.clip(ClipID($0)) }
        #expect(clips.allSatisfy { $0?.clip.start == 48_000 }, "each clip is at the drop frame")
        #expect(studio.session.track("t1") == t1, "t1 does not change")
        #expect(model.timeline.selection == ClipSet(["A", "B"]).map { .clips($0) }, "both clips are selected")
        #expect(model.alert == nil)
        await model.close()
    }

    /// C6 b: a file with 3 channels is skipped, the chain goes on, and one alert names the file.
    @Test func aBadMiddleFileIsSkippedAndNamed() async throws {
        let (model, studio, view) = try await open()
        let files = [try wav("A.wav"), try wav("Mid.wav", channels: 3), try wav("C.wav")]

        #expect(await drop(files, at: NSPoint(x: 100, y: 30), in: view, model))

        #expect(studio.session.tracks.map(\.name) == ["T1", "T2", "A", "C"], "files 1 and 3 import")
        #expect(
            model.alert == .importChain([.audioImport(.tooManyChannels(file: "Mid.wav", channels: 3))], notImported: [])
        )
        await model.close()
    }

    /// C6: a full disk stops the chain; the alert gives the error and each file not imported.
    @Test func aFullDiskStopsTheChainAndNamesTheRest() async throws {
        let (model, studio, view) = try await open()
        studio.environment.freeBytes = { _ in 0 }

        #expect(await drop([try wav("A.wav"), try wav("B.wav")], at: NSPoint(x: 100, y: 30), in: view, model))

        #expect(studio.session.tracks.count == 2, "nothing imports")
        guard case .importChain(let errors, let rest) = model.alert,
            case .audioImport(.space(let file, _, _)) = errors.first
        else {
            Issue.record("no stop alert: \(String(describing: model.alert))")
            return await model.close()
        }
        #expect(errors.count == 1 && file == "A.wav" && rest == ["B.wav"], "the error of A and the name of B")
        await model.close()
    }

    /// C6: a cancel stops the chain; the alert names only the skipped files.
    @Test func aCancelShowsOnlyTheSkippedFiles() async throws {
        let (model, studio, view) = try await open()
        let hold = DispatchSemaphore(value: 0)
        let entered = LockedFlag()
        studio.environment.importStep = {
            guard !entered.value else { return }
            entered.value = true
            _ = hold.wait(timeout: .now() + 30)
        }
        let files = [try wav("Mid.wav", channels: 3), try wav("A.wav"), try wav("B.wav")]
        let drag = fileDrag(files, at: NSPoint(x: 100, y: 30), in: view)
        #expect(view.draggingEntered(drag) == .copy && view.performDragOperation(drag))
        view.draggingEnded(drag)
        await until("the import of A holds") { entered.value }

        model.cancelImport()
        hold.signal()
        await until("the chain ends") { model.importJob == nil }

        #expect(studio.session.tracks.count == 2, "no file imports")
        #expect(
            model.alert == .importChain([.audioImport(.tooManyChannels(file: "Mid.wav", channels: 3))], notImported: [])
        )
        await model.close()
    }

    /// C8: a point over the track headers or the time ruler gets no operation.
    @Test func aDragOverTheHeadersGetsNoOperation() async throws {
        let (model, _, view) = try await open()
        let voice = try wav("Voice.wav")
        let shown = view.shown
        let points = [
            ("the headers", NSPoint(x: shown.minX - 20, y: 30)), ("the ruler", NSPoint(x: 100, y: shown.minY - 10)),
            ("the lanes", NSPoint(x: 100, y: 30)),
        ]
        for (place, point) in points {
            let drag = fileDrag([voice], at: point, in: view)
            #expect(view.draggingEntered(drag) == (place == "the lanes" ? .copy : []), "\(place)")
            view.draggingExited(drag)
        }
        await model.close()
    }

    /// C15 b: a paste from another package commits the name typed in a header first.
    @Test func aCrossPackagePasteCommitsATypedTrackName() async throws {
        var packages: [URL] = []
        for name in ["a", "b"] {
            let folder = self.folder.url.appending(path: name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            packages.append(try await timelinePackage(in: folder, tracks: 2, seconds: 2, audio: true))
        }
        let (first, _, _, _) = try await openLanes(app, packages[0])
        first.timeline.marks = Marks(inPoint: 0, outPoint: 48_000, tracks: ["t1"])
        first.run(.copy)
        await first.close()
        let (second, studio, _, _) = try await openLanes(app, packages[1])
        studio.environment.playerOutput = .offline
        second.timeline.selection = .range(Marks(tracks: ["t2"]))
        second.drafts["t1"] = "Typed"

        second.run(.paste)
        await until("the paste ends") { second.importJob == nil }

        #expect(studio.session.files["f1 2"] != nil && second.alert == nil, "the paste copied the file")
        #expect(studio.session.track("t1")?.name == "Typed", "the typed name is saved")
        await second.close()
    }
}

/// C2 c: a drag with a pending take gets no operation.
extension EditTakeTests {
    @Test func aDragWithAPendingTakeGetsNoOperation() async throws {
        let (model, studio, _, view) = try await openLanes(app, try await package())
        let voice = folder.url.appending(path: "Voice.wav")
        try writeSilentWAV(voice, channels: 1)
        let idle = fileDrag([voice], at: NSPoint(x: 100, y: 30), in: view)
        #expect(view.draggingEntered(idle) == .copy, "an idle window gets copy")
        view.draggingExited(idle)
        try await pendingTake(model, studio)

        let drag = fileDrag([voice], at: NSPoint(x: 100, y: 30), in: view)
        #expect(view.draggingEntered(drag) == [], "a pending take")
        view.draggingExited(drag)
        await model.close()
    }
}

/// The pasteboard of the fake drags. A test writes it and enters the drag with no await between.
@MainActor let dropBoard = NSPasteboard.withUniqueName()

/// A drag of `urls` at the lane point `point` of `view`.
@MainActor func fileDrag(_ urls: [URL], at point: NSPoint, in view: TimelineScrollView) -> FakeDrag {
    dropBoard.clearContents()
    dropBoard.writeObjects(urls.map { $0 as NSURL })
    return FakeDrag(dropBoard, at: view.lanes.convert(point, to: nil))
}

/// A drag that AppKit would give, with a pasteboard and a window point only (probe P5).
@MainActor final class FakeDrag: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    var numberOfValidItemsForDrop = 0

    init(_ pasteboard: NSPasteboard, at point: NSPoint) { (draggingPasteboard, draggingLocation) = (pasteboard, point) }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set {}
    }
    var animatesToDestination: Bool {
        get { false }
        set {}
    }
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// A 16-bit WAV of 1 s of silence at 48 kHz with `channels` channels.
func writeSilentWAV(_ url: URL, channels: Int) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    let bytes = 48_000 * channels * 2
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + bytes))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(channels))
    append(UInt32(48_000))
    append(UInt32(48_000 * channels * 2))
    append(UInt16(channels * 2))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(bytes))
    data.append(Data(count: bytes))
    try data.write(to: url)
}
