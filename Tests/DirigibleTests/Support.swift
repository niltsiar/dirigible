import AVFoundation
import AppKit
import DirigibleCore
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

/// A unique temporary folder under `parent`, removed at deinit.
final class TemporaryFolder {
    let url: URL

    init(in parent: URL = FileManager.default.temporaryDirectory) throws {
        url = parent.appending(path: "DirigibleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

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
            attach: { [counts] _ in
                counts.withLock { $0.attaches += 1 }
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
}

/// A package with the mono tracks `t1` to `t<tracks>`, each routed to channel 1 of `mic` and
/// each with a clip of file `f1` from 0 for `seconds`. With `audio`, `f1` is a WAV of silence on
/// disk; else the file is missing. The writes run off the main actor (the tdd skill).
func timelinePackage(in folder: URL, tracks: Int, seconds: Int, audio: Bool = false) async throws -> URL {
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
            try session.setRoute(Route(deviceUID: "mic", channels: .mono(1)), track: track)
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

/// A window with lanes of 1440 x 400 pt (the track headers take their width on the left), with
/// the lanes of `model` at 512 frames per point and 100 pt lanes, drawn once. It is on screen only with `onScreen` (a display link needs a screen); the other
/// tests keep the window server load of the suite low.
@MainActor func standaloneLanes(_ model: SessionWindow, _ studio: Studio, onScreen: Bool = false)
    -> (NSWindow, TimelineScrollView)
{
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1440 + TrackHeaderRuler.width, height: 400), styleMask: [.borderless],
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

/// The document view of `session` alone (no window), at 512 frames per point and 100 pt lanes.
@MainActor func documentView(_ session: Session) -> TimelineDocumentView {
    let view = TimelineDocumentView()
    view.inputs = LaneInputs(
        session: session, peaks: [:], missingMedia: [:], marks: Marks(), scale: TimelineScale(framesPerPoint: 512),
        laneHeight: 100)
    return view
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
