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
/// The default limit is 60 s, longer than the whole suite: in a full run, the DirigibleAudio
/// tests hold the main actor (`PendingTakeTests.init` and `Studio.startTake` write with
/// `F_FULLFSYNC`) and the cooperative threads (blocking file writes) for most of the run, and a
/// window open needs both.
@MainActor func until(limit: Duration = .seconds(60), _ message: String, _ condition: () -> Bool) async {
    let end = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < end else {
            Issue.record("\(message) (limit \(limit))")
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

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

/// A closure `DeviceHAL` with one device `duo` (2 channels, 48 kHz, object 7). It counts the
/// attaches and the clean detaches; "the device is free" is `attaches == cleanDetaches`. The app
/// test target cannot import `TestHAL` of `DirigibleAudioTests`.
final class CountingHAL: Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: (attaches: 0, cleanDetaches: 0))
    private let inputs = OSAllocatedUnfairLock(initialState: [DeviceInput]())

    var attaches: Int { counts.withLock { $0.attaches } }
    var isFree: Bool { counts.withLock { $0.attaches == $0.cleanDetaches } }

    /// The live environment with this HAL, the access granted, and a watchdog limit of 60 s, so
    /// a device with no records is never lost in a test.
    var environment: CaptureEnvironment {
        let duo = InputDevice(
            uid: "duo", name: "Duo", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [2],
            latency: 0)!
        var environment = CaptureEnvironment.live
        environment.hal = DeviceHAL(
            lookUp: { $0 == duo.uid ? (7, duo) : nil },
            attach: { [counts, inputs] input in
                counts.withLock { $0.attaches += 1 }
                inputs.withLock { $0.append(input) }
                return {
                    counts.withLock { $0.cleanDetaches += 1 }
                    return true
                }
            }, watchDevices: { _ in { true } })
        environment.microphoneAccess = { nil }
        environment.silenceLimit = .seconds(60)
        environment.firstRecordLimit = .seconds(60)
        return environment
    }

    /// Pushes `seconds` of stereo silence into the ring of the last attached input, as the IOProc
    /// does: records of 10 ms from now. The device writer drains them into the take. The writer
    /// attaches on its queue after the transport change, so it first waits (60 s limit) until an
    /// input is attached and not detached.
    @MainActor func feed(seconds: Double) async {
        await until("no input is attached") { !isFree }
        guard let input = inputs.withLock({ $0.last }) else {
            Issue.record("No input is attached")
            return
        }
        input.ring.setRate(48_000)
        let start = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        for n in 0..<Int(seconds * 100) {
            var time = AudioTimeStamp()
            time.mSampleTime = Double(n * 480)
            time.mHostTime = AudioConvertNanosToHostTime(start + UInt64(n) * 10_000_000)
            time.mRateScalar = 1
            time.mFlags = [.sampleTimeValid, .hostTimeValid]
            var samples = [Float](repeating: 0, count: 960)
            samples.withUnsafeMutableBytes { bytes in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
                var output = AudioBufferList()
                withUnsafePointer(to: time) { time in
                    _ = CaptureRing.ioProc(7, time, &list, time, &output, time, input.ring.context)
                }
            }
        }
    }
}

/// Counts the package writes of a studio. Each write still goes to the disk.
final class SaveCounter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var writes: Int { count.withLock { $0 } }

    @MainActor init(_ studio: Studio) {
        let save = studio.environment.saveSession
        studio.environment.saveSession = { [count] session, lock throws(SessionFileError) in
            count.withLock { $0 += 1 }
            return try save(session, lock)
        }
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

@MainActor private func firstEditableField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    return view.subviews.lazy.compactMap(firstEditableField).first
}

/// A package with the mono tracks `t1` to `t<tracks>`, each routed to channel 1 of `device` and
/// each with a clip of file `f1` from 0 for `seconds`. With `audio`, `f1` is a WAV of silence on
/// disk; else the file is missing. The writes run off the main actor (the tdd skill).
func timelinePackage(
    in folder: URL, tracks: Int, seconds: Int, audio: Bool = false, device: String = "mic"
) async throws -> URL {
    let url = folder.appending(path: "timeline.dirigible")
    try await Task.detached {
        try Session.create(at: url, sampleRate: 48_000)
        var session = Session(sampleRate: 48_000)
        let frames = 48_000 * seconds
        if audio {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let writer = try ClipWriter(
                url: url.appending(path: "\(clipsFolderName)/f1.wav"), file: "f1.wav", format: format)
            try writer.write(buffer)
            try writer.close()
        }
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: Frames(frames)))
        for n in 1...tracks {
            let track = TrackID("t\(n)")
            try session.addTrack(track, name: "T\(n)", layout: .mono)
            try session.setRoute(Route(deviceUID: device, channels: .mono(1)), track: track)
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
    _ type: NSEvent.EventType, _ point: NSPoint, in view: TimelineScrollView, flags: NSEvent.ModifierFlags = []
) throws -> NSEvent {
    try #require(
        NSEvent.mouseEvent(
            with: type, location: view.lanes.convert(point, to: nil), modifierFlags: flags, timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
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

@MainActor func laneInputs(_ model: SessionWindow, _ studio: Studio, marks: Marks = Marks()) -> LaneInputs {
    LaneInputs(
        session: studio.session, peaks: studio.peaks, missingMedia: studio.missingMedia, marks: marks,
        scale: TimelineScale(framesPerPoint: 512), laneHeight: 100)
}

/// The document view of `session` alone in a borderless window of its size, at 512 frames per
/// point and 100 pt lanes, drawn once. The lanes draw in `updateLayer()`, so a snapshot of a view
/// with no window has no lanes.
@MainActor func documentView(_ session: Session) -> (NSWindow, TimelineDocumentView) {
    let view = TimelineDocumentView()
    view.inputs = LaneInputs(
        session: session, peaks: [:], missingMedia: [:], marks: Marks(), scale: TimelineScale(framesPerPoint: 512),
        laneHeight: 100)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: view.frame.size), styleMask: [.borderless], backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
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

/// Holds the first caller of `wait` until `open`, with a limit of 30 s. It polls, so it blocks
/// no thread of the concurrency pool. Later callers pass. A copy of the gate of
/// `DirigibleAudioTests`: the test targets share no code.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    private var inside = false
    private var opened = false

    func wait() async {
        guard
            lock.withLock({ () -> Bool in
                defer { used = true }
                inside = !used
                return !used
            })
        else { return }
        let end = ContinuousClock.now + .seconds(30)
        while !lock.withLock({ opened }) {
            guard ContinuousClock.now < end else {
                Issue.record("The gate was not opened in 30 s")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func open() { lock.withLock { opened = true } }

    /// Returns when the first caller is inside `wait`. After `limit`, it records a failure.
    func entered(limit: Duration = .seconds(30)) async {
        let end = ContinuousClock.now + limit
        while !lock.withLock({ inside }) {
            guard ContinuousClock.now < end else {
                Issue.record("No block entered the gate (limit \(limit))")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
