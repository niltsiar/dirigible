import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 2026-10-16-observation-hang C1 to C4: a meter report runs no track row body and makes no
/// registration on a stable key path, and a state report still runs the row. On macOS 14 a
/// registration that a body run makes again can stay until the next change of its key path, and
/// that change then cancels all of them on the main thread.
@Suite(.serialized) @MainActor struct HeaderMeterRateTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    /// A session window with 2 armed tracks in the monitor state, drawn with both meters.
    func open() async throws -> (SessionWindow, Studio, NSWindow, TimelineScrollView) {
        let (model, studio, window, view) = try await openLanes(
            app, try await timelinePackage(in: folder.url, tracks: 2, seconds: 20))
        model.armed = ["t1", "t2"]
        for id in ["t1", "t2"] as [TrackID] {
            studio.liveTracks[id] = LiveTrack(state: .monitoring, droppedFrames: 0, peak: 0)
        }
        await until("the rows show both meters") {
            update(window)
            return meters(view).count == 2
        }
        return (model, studio, window, view)
    }

    /// One window update, as the main run loop gives it after a report.
    func update(_ window: NSWindow) {
        RunLoop.main.run(until: Date())
        window.contentView?.layoutSubtreeIfNeeded()
        drawNow(window)
    }

    /// The level of each meter of the headers on its 0 to 1 scale, top row first.
    func meters(_ view: TimelineScrollView) -> [Double] {
        func indicators(_ view: NSView) -> [NSProgressIndicator] {
            (view as? NSProgressIndicator).map { [$0] } ?? view.subviews.flatMap(indicators)
        }
        return indicators(view.headers.host)
            .sorted { $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY }
            .map { ($0.doubleValue - $0.minValue) / ($0.maxValue - $0.minValue) }
    }

    @Test func meterReportsRunNoRowBody() async throws {
        let (model, studio, window, view) = try await open()
        let rows = model.headerRuns.rows
        let observed = try #require(registrations(of: studio)).ids[\Studio.liveTracks]?.count ?? 0
        var made: [String: Int] = [:]
        for tick in 1...100 {
            let studioBefore = try #require(registrations(of: studio))
            let windowBefore = try #require(registrations(of: model))
            // -20 dBFS and -40 dBFS at the last report: 2/3 and 1/3 of the meter scale.
            let peaks: (Float, Float) = tick == 100 ? (0.1, 0.01) : (Float(tick % 50 + 1) / 100, 0.5)
            studio.liveTracks["t1"]?.peak = peaks.0
            studio.liveTracks["t2"]?.peak = peaks.1
            update(window)
            let studioAfter = try #require(registrations(of: studio))
            let windowAfter = try #require(registrations(of: model))
            for (path, count) in studioAfter.made(since: studioBefore.next) where path != \Studio.liveTracks {
                made["\(path)", default: 0] += count
            }
            for (path, count) in windowAfter.made(since: windowBefore.next) { made["\(path)", default: 0] += count }
        }
        let levels = meters(view)
        let follows = levels.count == 2 && abs(levels[0] - 2.0 / 3) < 0.001 && abs(levels[1] - 1.0 / 3) < 0.001
        #expect(follows, "C3: the meters show the last peaks: \(levels)")
        #expect(
            model.headerRuns.rows - rows == 0, "C1: row bodies at 100 meter reports: \(model.headerRuns.rows - rows)")
        let stable = made.isEmpty
        #expect(stable, "C2: new registrations at 100 meter reports: \(made.sorted { $0.key < $1.key })")
        let live = try #require(registrations(of: studio)).ids[\Studio.liveTracks]?.count ?? 0
        #expect(
            live <= levels.count,
            "only the meter views observe liveTracks: \(observed) live before, \(live) after, \(levels.count) meters")
        window.close()
        await model.close()
    }

    /// A model whose monitor of device "mic" holds tracks t1 and t2 (arms 1 and 2), both in the
    /// monitor state. The writer of the monitor does not start.
    func monitored() async throws -> (SessionWindow, Studio) {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 1), app: app)
        let device = try #require(InputDevice.placeholder(uid: "mic", channels: 1))
        let writer = DeviceWriter(
            device: device, tracks: [(arm: 1, channels: .mono(1)), (arm: 2, channels: .mono(1))], files: nil,
            hal: CountingHAL().environment.hal)
        studio.monitors["mic"] = Monitor(
            writer: writer, source: .device(uid: "mic"),
            tracks: [MonitoredTrack(id: "t1", channels: .mono(1)), MonitoredTrack(id: "t2", channels: .mono(1))],
            number: 1)
        for id in ["t1", "t2"] as [TrackID] {
            studio.liveTracks[id] = LiveTrack(state: .monitoring, droppedFrames: 0, peak: 0)
        }
        return (model, studio)
    }

    /// A monitor meter report of 2 tracks writes `liveTracks` once, so its `didSet` builds the
    /// states once for the report.
    @Test func oneDidSetForEachReport() async throws {
        let (model, studio) = try await monitored()
        let writes = studio.liveTrackWrites
        for tick in 1...100 {
            let arms = [1: ArmLevel(peak: Float(tick) / 200), 2: ArmLevel(peak: 0.25)]
            studio.applyMonitor(
                .levels(take: 0, arms: arms, latencyNanos: 0, droppedFrames: tick), number: 1, uid: "mic")
        }
        #expect(studio.liveTrackWrites - writes == 100, "writes for 100 reports: \(studio.liveTrackWrites - writes)")
        #expect(
            studio.liveTracks["t1"] == LiveTrack(state: .monitoring, droppedFrames: 100, peak: 0.5)
                && studio.liveTracks["t2"] == LiveTrack(state: .monitoring, droppedFrames: 100, peak: 0.25),
            "the last report: \(studio.liveTracks)")
        studio.monitors = [:]
        await model.close()
    }

    /// A meter report whose arm maps to no track of the monitor writes no `liveTracks`, so it runs
    /// no `didSet` and no meter view. A report of arm 1 then writes once.
    @Test func aReportOfNoTrackWritesNothing() async throws {
        let (model, studio) = try await monitored()
        let writes = studio.liveTrackWrites
        studio.applyMonitor(
            .levels(take: 0, arms: [3: ArmLevel(peak: 0.5)], latencyNanos: 0, droppedFrames: 7), number: 1, uid: "mic")
        #expect(
            studio.liveTrackWrites - writes == 0, "writes for a report of arm 3: \(studio.liveTrackWrites - writes)")
        studio.applyMonitor(
            .levels(take: 0, arms: [1: ArmLevel(peak: 0.5)], latencyNanos: 0, droppedFrames: 7), number: 1, uid: "mic")
        #expect(
            studio.liveTrackWrites - writes == 1
                && studio.liveTracks["t1"] == LiveTrack(state: .monitoring, droppedFrames: 7, peak: 0.5),
            "a report of arm 1: \(studio.liveTrackWrites - writes) writes, \(String(describing: studio.liveTracks["t1"]))"
        )
        studio.monitors = [:]
        await model.close()
    }

    /// C4, the control of C1: a state report runs the row of its track, and the row shows the
    /// state in red right of the arm boxes. Light, as `HeaderRowTests.armRed`.
    @Test func aStateReportRunsTheRow() async throws {
        let (model, studio, window, view) = try await open()
        window.appearance = NSAppearance(named: .aqua)
        /// The red pixels right of the arm boxes in each row, top row first.
        func red() async throws -> [Int] {
            window.orderFront(nil)
            drawNow(window)
            try await Task.sleep(for: .milliseconds(200))
            let capture = try await TimelineColorTests.capture(window)
            let arms = try headerBoxRows(in: view).map { $0[0] }
            try #require(arms.count == 2, "2 rows of boxes: \(arms)")
            let host = view.headers.host.convert(view.headers.host.bounds, to: nil)
            let left = try #require(arms.map(\.maxX).max()) + 1
            // Row 1 starts at the top of the host; row 2 at the top of its own arm box.
            let split = arms[1].maxY + 1
            return try [(split, host.maxY), (host.minY, split)].map { bottom, top in
                let band = NSRect(x: left, y: bottom, width: host.maxX - left, height: top - bottom)
                return try TimelineRulerTests.pixels(of: band, capture, window).filter(HeaderRowTests.isRed).count
            }
        }
        #expect(try await red() == [0, 0], "no red right of the arm boxes while both tracks monitor")
        let runs = model.headerRuns.rows
        studio.liveTracks["t1"]?.state = .deviceLost
        studio.liveTracks["t1"]?.peak = 0
        await until("the row of t1 takes the state") {
            update(window)
            return model.headerRuns.rows > runs
        }
        let shown = try await red()
        #expect(shown[0] > 10 && shown[1] == 0, "C4: the device lost text shows in the row of t1 only: \(shown)")
        window.close()
        await model.close()
    }
}
