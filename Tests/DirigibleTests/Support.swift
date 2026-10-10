import AVFoundation
import AppKit
import CoreAudio
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// Polls `condition` every 10 ms. At the limit, it records `message` as an issue and returns.
/// It checks once more after a sleep past the limit, so a main-queue job that a stall queued
/// behind the poll (for example the retry of a refused draw) runs before the last check, as in
/// the copy of `DirigibleAudioTests`. The default limit stays 60 s. The worst wait of this copy was 70.4 s at
/// the suite start ("the launch prunes the peak cache", run test-pool-health, loops/s3q-20.log;
/// 58.5 s in two processes under load, loops/s3loadb-1.log). The hang guards are 3 times the
/// worst wait, but 3 times 70.4 s is longer than one suite run (about 200 s).
@MainActor func until(limit: Duration = .seconds(60), _ message: String, _ condition: () -> Bool) async {
    let start = ContinuousClock.now
    defer { reportWait("until", since: start, message) }
    let end = start + limit
    var expired = false
    while !condition() {
        guard !expired else {
            Issue.record("\(message) (limit \(limit))")
            return
        }
        expired = ContinuousClock.now >= end
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// The silence and first-record limit of a test writer that no test reaches: one day. A loaded
/// full suite holds a test for more than 60 s, and a watchdog that fires in a test gives a second
/// attach that the test did not ask for. A watchdog test sets its own limit. A copy of the
/// constant of `DirigibleAudioTests`.
let noWatchdog = Duration.seconds(86_400)

/// With `DIRIGIBLE_FLAKE_MONITOR` set, prints `WAIT <helper> <seconds> s <text>` for a wait over
/// 2 s. `scripts/flake-monitor/loop.sh` takes the worst wait of each helper, and the hang guards
/// take their limits from it. A copy of the function of `DirigibleAudioTests`.
func reportWait(_ helper: String, since start: ContinuousClock.Instant, _ text: String) {
    guard flakeMonitorIsOn else { return }
    let seconds = (ContinuousClock.now - start) / .seconds(1)
    if seconds > 2 { print(String(format: "WAIT %@ %.1f s %@", helper, seconds, text)) }
}

private let flakeMonitorIsOn = ProcessInfo.processInfo.environment["DIRIGIBLE_FLAKE_MONITOR"] != nil

/// A unique temporary folder under `parent`, removed at deinit off the calling thread.
/// The deinit of a folder in a `@MainActor` suite runs on the main thread. A synchronous
/// remove there held the main actor for a third of a full run (process sample, 2026-09-25).
final class TemporaryFolder {
    let url: URL

    init(in parent: URL = FileManager.default.temporaryDirectory) throws {
        url = parent.appending(path: "DirigibleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { FolderRemovals.remove(url) }

    /// A new session package in the folder.
    func package(_ name: String) throws -> URL {
        let url = url.appending(path: "\(name).dirigible")
        try Session.create(at: url, sampleRate: 48_000)
        return url
    }
}

extension SessionWindow {
    /// Waits until the open of the package ends with a studio.
    func opened() async -> Bool {
        await until("the window opens its package") { studio != nil }
        if studio == nil { Issue.record("The phase is \(phase)") }
        return studio != nil
    }
}

/// A key event from `CGEvent`: its key code matches a menu item as a real key does (probe E4).
/// Backspace is 51, Return 36, Left 123, Right 124, Page Down 121.
func cgKey(_ code: UInt16, _ flags: CGEventFlags = []) throws -> NSEvent {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
    event.flags = flags
    return try #require(NSEvent(cgEvent: event))
}

/// A key-down with Command from `NSEvent.keyEvent`: a CGEvent key-down types nothing in the
/// field editor of the test process (decisions.tsv, slice 2). An arrow also has the function
/// and number-pad flags, as a real arrow key has.
@MainActor func commandKey(_ characters: String, code: UInt16, in window: NSWindow) -> NSEvent {
    let arrow = code == 123 || code == 124
    return NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: arrow ? [.command, .function, .numericPad] : .command,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
}

/// A real session window of `package` with its lanes, as the key window of `app`.
@MainActor func openLanes(_ app: AppDelegate, _ package: URL) async throws
    -> (SessionWindow, Studio, NSWindow, TimelineScrollView)
{
    let model = await app.open(package)
    let studio = try #require(await model.opened() ? model.studio : nil)
    let window = try #require(model.window)
    await until("the window shows the lanes") { model.timelineView?.window != nil }
    app.key = model
    return (model, studio, window, try #require(model.timelineView))
}

/// Focuses the name field of the first track and returns its field editor.
@MainActor func focusName(in window: NSWindow) async throws -> NSTextView {
    var found: NSTextField?
    await until("the track header shows its name field") {
        window.contentView?.layoutSubtreeIfNeeded()
        found = window.contentView.flatMap(firstEditableField)
        return found != nil
    }
    let field = try #require(found)
    #expect(window.makeFirstResponder(field))
    return try #require(window.fieldEditor(false, for: field) as? NSTextView)
}

@MainActor func firstEditableField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    return view.subviews.lazy.compactMap(firstEditableField).first
}

/// A package with the mono tracks `t1` to `t<tracks>`, each routed to channel 1 of `device` and
/// each with a clip of file `f1` from 0 for `seconds`. With `audio`, `f1` is a WAV of silence on
/// disk; with `noise`, a WAV of noise whose level changes every 0.5 s (a waveform to draw); else
/// the file is missing. The writes run off the main actor (the tdd skill).
func timelinePackage(
    in folder: URL, tracks: Int, seconds: Int, audio: Bool = false, noise: Bool = false, device: String = "mic"
) async throws -> URL {
    let url = folder.appending(path: "timeline.dirigible")
    try await Task.detached {
        try Session.create(at: url, sampleRate: 48_000)
        var session = Session(sampleRate: 48_000)
        let frames = 48_000 * seconds
        if audio || noise {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            if noise, let samples = buffer.floatChannelData?[0] {
                // The same noise on each run: a linear congruential generator.
                var state: UInt64 = 1
                for n in 0..<frames {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    let level = [0.1, 0.5, 0.9, 0.3][(n / 24_000) % 4]
                    samples[n] = Float(level * (Double(state >> 11) / Double(1 << 53) * 2 - 1))
                }
            }
            let writer = try ClipWriter(
                url: url.appending(path: "\(clipsFolderName)/f1.wav"), file: "f1.wav", format: format)
            try writer.write(buffer)
            try writer.close()
        }
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: Frames(frames)))
        for n in 1...tracks {
            let track = TrackID("t\(n)")
            try session.addTrack(track, name: "T\(n)", layout: .mono)
            try session.setRoute(Route.device(uid: device, channels: .mono(1)), track: track)
            try session.place(
                Clip(id: ClipID("c\(n)"), file: "f1", start: 0, offset: 0, length: Frames(frames)), on: track)
        }
        try session.write(to: url)
    }.value
    return url
}

/// A session window model with an open studio and no window of its own, so only the lanes of the
/// test draw and publish.
@MainActor func timelineModel(_ package: URL, app: AppDelegate) async throws -> (SessionWindow, Studio) {
    let model = SessionWindow(url: package, recordings: nil, app: app)
    model.open(recovering: false)
    let studio = try #require(await model.opened() ? model.studio : nil)
    return (model, studio)
}

/// The width that a scroller takes from the lanes in the preferred style: a legacy scroller takes
/// its width, and an overlay scroller takes none. A fixture window adds it, so the lanes in view
/// keep their size in both styles.
@MainActor let scrollerWidth =
    NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0

/// A window with lanes of 1440 x 400 pt (the track headers take their width on the left), with
/// the lanes of `model` at 512 frames per point and 100 pt lanes, drawn once. It is on screen only with `onScreen` (a display link needs a screen); the other
/// tests keep the window server load of the suite low.
@MainActor func standaloneLanes(_ model: SessionWindow, _ studio: Studio, onScreen: Bool = false)
    -> (NSWindow, TimelineScrollView)
{
    let window = NSWindow(
        contentRect: NSRect(
            x: 0, y: 0, width: 1440 + HeaderWidth.standard.points + scrollerWidth, height: 400 + scrollerWidth),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    // The pixel tests read the light palette on a Mac in Dark Mode too (probe Q3).
    window.appearance = NSAppearance(named: .aqua)
    let view = TimelineScrollView(model: model, studio: studio)
    view.frame = window.contentView!.bounds
    window.contentView!.addSubview(view)
    view.update(laneInputs(model, studio))
    // The first update fits the session; the tests use 512 frames per point.
    view.update(laneInputs(model, studio))
    if onScreen { window.orderFront(nil) }
    drawNow(window)
    return (window, view)
}

/// A mouse event at the document point `point` of the lanes of `view`.
@MainActor func mouse(
    _ type: NSEvent.EventType, _ point: NSPoint, in view: TimelineScrollView, flags: NSEvent.ModifierFlags = [],
    clicks: Int = 1
) throws -> NSEvent {
    try #require(
        NSEvent.mouseEvent(
            with: type, location: view.lanes.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: clicks,
            pressure: 1))
}

/// A mouse event on the time ruler of `view`: at the document x `x` and the ruler y `y` (the ruler
/// is flipped: y 0 is its top).
@MainActor func rulerMouse(
    _ type: NSEvent.EventType, _ x: Double, _ y: Double, in view: TimelineScrollView
) throws -> NSEvent {
    let location = NSPoint(
        x: view.lanes.convert(NSPoint(x: x, y: 0), to: nil).x, y: view.ruler.convert(NSPoint(x: 0, y: y), to: nil).y)
    return try #require(
        NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
}

/// Draws what needs a draw now: a layer-backed view draws at the commit of the Core Animation
/// transaction, not in `displayIfNeeded()`.
@MainActor func drawNow(_ window: NSWindow) {
    window.displayIfNeeded()
    CATransaction.flush()
}

/// Test shims of decision 0038: the range tests read and write the window selection as Marks.
extension TimelineState {
    var marks: Marks? {
        get { selection.marks }
        set { selection = .range(newValue ?? Marks()) }
    }
}

extension ClipInspection {
    init?(marks: Marks, session: Session) { self.init(selection: .range(marks), session: session) }
}

@MainActor func laneInputs(_ model: SessionWindow, _ studio: Studio, selection: Selection = .none) -> LaneInputs {
    LaneInputs(
        session: studio.session, peaks: studio.peaks, missingMedia: studio.missingMedia, selection: selection,
        scale: TimelineScale(framesPerPoint: 512), laneHeight: 100)
}

/// The document view of `session` alone in a borderless window of its size, at 512 frames per
/// point and 100 pt lanes, drawn once. The lanes draw in `updateLayer()`, so a snapshot of a view
/// with no window has no lanes.
@MainActor func documentView(_ session: Session) -> (NSWindow, TimelineDocumentView) {
    let view = TimelineDocumentView()
    view.inputs = LaneInputs(
        session: session, peaks: [:], missingMedia: [:], selection: .none, scale: TimelineScale(framesPerPoint: 512),
        laneHeight: 100)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: view.frame.size), styleMask: [.borderless], backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = view
    drawNow(window)
    return (window, view)
}

/// The pixels darker than 40% gray (the clip label color) of a draw of `rect` of `view`. The lane
/// and clip colors are lighter.
@MainActor func darkPixels(_ view: NSView, in rect: NSRect) throws -> Int {
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: rect))
    view.cacheDisplay(in: rect, to: bitmap)
    var count = 0
    for x in 0..<bitmap.pixelsWide {
        for y in 0..<bitmap.pixelsHigh {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.redComponent + color.greenComponent + color.blueComponent < 1.2 { count += 1 }
        }
    }
    return count
}

/// The peaks of a mono file of `frames` frames at 48 kHz: random peaks (the same on each run),
/// RMS at half the peak, at the levels of 256, 4,096, and 65,536 frames per column.
func randomPeaks(frames: Int) -> Peaks {
    var random = SplitMix(seed: 9)
    let base = (0..<(frames / 256)).map { _ in
        let peak = UInt16.random(in: 0...65535, using: &random)
        return PeakColumn(peak: peak, rms: peak / 2)
    }
    func upper(_ factor: Int) -> [PeakColumn] {
        stride(from: 0, to: base.count, by: factor).map { start in
            let bins = base[start..<min(start + factor, base.count)]
            return PeakColumn(peak: bins.map(\.peak).max()!, rms: bins.map(\.rms).max()!)
        }
    }
    return Peaks(
        frames: Frames(frames), stamp: FileStamp(size: 0, seconds: 0, nanoseconds: 0), channels: 1,
        sampleRate: 48_000, levels: [base, upper(16), upper(256)])
}

/// Removes folders one at a time on a serial utility queue, so parallel deinits do not add
/// threads that compete for the disk. The process waits for the removals at exit, so no folder
/// stays in the temporary directory.
enum FolderRemovals {
    private static let queue = DispatchQueue(label: "FolderRemovals", qos: .utility)
    private static let group: DispatchGroup = {
        atexit { FolderRemovals.group.wait() }
        return DispatchGroup()
    }()

    static func remove(_ url: URL) {
        queue.async(group: group) { try? FileManager.default.removeItem(at: url) }
    }
}
