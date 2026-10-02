import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The process set and output events of an app writer (A7, A8): a found set with a new process
/// or a new output rebuilds the tap into a new segment; a set that only loses processes keeps it.
/// Each "no rebuild" case also proves that the event reached the writer: a new lookup.
@MainActor
struct AppEventTests {
    static let zoom = "us.zoom.xos"
    static let uid = "app:us.zoom.xos"
    let folder: TemporaryFolder
    let log = ReportLog()
    let hal = TestHAL([])

    init() throws { folder = try TemporaryFolder() }

    /// `output` is the output that a matched process reports (nil: none); `main` is the main
    /// sub-device, the reported output or else the default output.
    func found(_ processes: [AudioObjectID], output: String? = "BuiltInSpeakerDevice", main: String? = nil)
        -> AppFound
    {
        AppFound(
            key: AppKey(processes: processes, output: output), output: main ?? output ?? "BuiltInSpeakerDevice",
            device: InputDevice(
                uid: Self.uid, name: Self.zoom, nominalRate: 48_000, availableRates: [48_000...48_000],
                channelsPerBuffer: [1], latency: 0)!,
            playing: !processes.isEmpty)
    }

    /// A started app writer of arm 1 (mono) whose app has `processes` now. The watchdog limits
    /// are long, so a busy suite gets no second attach before a check.
    func writer(_ processes: [AudioObjectID], output: String? = "BuiltInSpeakerDevice") async -> DeviceWriter {
        hal.setApp(Self.zoom, found(processes, output: output, main: "BuiltInSpeakerDevice"))
        let url = folder.url
        let device = InputDevice(
            uid: Self.uid, name: "zoom.us", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelsPerBuffer: [1], latency: 0)!
        let writer = DeviceWriter(
            device: device, tracks: [(arm: 1, channels: .mono(1))], files: TakeFiles(take: 1, folder: { url }),
            hal: hal.hal, report: log.closure, silenceLimit: .seconds(60), firstRecordLimit: .seconds(60),
            app: Self.zoom)
        writer.start()
        await until("no first attach") { hal.inputs(Self.uid).count == 1 }
        return writer
    }

    /// The app has `processes` now, and the writer gets a list event. Waits for its lookup.
    func change(
        _ writer: DeviceWriter, to processes: [AudioObjectID], output: String? = "BuiltInSpeakerDevice",
        main: String? = nil
    ) async {
        hal.setApp(Self.zoom, found(processes, output: output, main: main))
        let lookups = hal.calls.count { $0.hasPrefix("lookUpApp") }
        writer.post(.devicesChanged, from: nil)
        await until("the event did not reach the writer") { hal.calls.count { $0.hasPrefix("lookUpApp") } > lookups }
    }

    /// Sends 0.2 s of records of `clock` into the current tap and waits for the drain.
    func play(_ clock: inout DeviceClock) async {
        let input = SyntheticInput(hal, Self.uid)
        input.play(clock.run(seconds: 0.2))
        await input.wait()
        await until("the ring is not empty") { hal.current(Self.uid)?.ring.isEmpty ?? true }
    }

    func stems() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
            .filter { $0.hasSuffix(".caf") }.map { String($0.dropLast(4)) }.sorted()
    }

    var taps: Int { hal.calls.count { $0.hasPrefix("makeTap") } }

    /// A7: a helper that starts rebuilds the tap into a new segment, with no gap. The clock goes
    /// on, so only the rebuild ends the first segment.
    @Test func aHelperThatStartsRebuildsIntoANewSegment() async throws {
        let writer = await writer([41])
        var clock = DeviceClock()
        await play(&clock)
        await change(writer, to: [41, 42])
        await until("no rebuild") { hal.inputs(Self.uid).count == 2 }
        await play(&clock)
        let gaps = await writer.finish()

        #expect(try stems() == ["take1-1-1", "take1-1-2"], "a new segment")
        #expect(taps == 2, "one rebuild")
        #expect(gaps.isEmpty, "a rebuild is no gap")
    }

    /// A7: the list changes with the same set (also the create of our own aggregate): no
    /// rebuild, and the segment goes on.
    @Test func aListChangeWithTheSameSetKeepsTheSegment() async throws {
        let writer = await writer([41])
        var clock = DeviceClock()
        await play(&clock)
        await change(writer, to: [41])
        await play(&clock)
        await writer.finish()

        #expect(taps == 1, "no rebuild")
        #expect(try stems() == ["take1-1-1"], "one segment")
    }

    /// A7: a helper that stops while another process stays keeps the tap.
    @Test func aHelperThatStopsKeepsTheSegment() async throws {
        let writer = await writer([41, 42])
        var clock = DeviceClock()
        await play(&clock)
        await change(writer, to: [41])
        await play(&clock)
        await writer.finish()

        #expect(taps == 1, "no rebuild")
        #expect(try stems() == ["take1-1-1"], "one segment")
    }

    /// A7: the app quits: no rebuild, the tap goes on with zeros, and the track waits. It starts
    /// again with the same process object: a rebuild (the slot took the empty set).
    @Test func anAppThatQuitsWaitsAndItsRestartRebuilds() async throws {
        let writer = await writer([41])
        var clock = DeviceClock()
        await play(&clock)
        await change(writer, to: [])
        await until("not waiting") { log.states(arm: 1).last == .waitingForApp }
        #expect(taps == 1, "a quit is no rebuild")
        await change(writer, to: [41])
        await until("no rebuild") { hal.inputs(Self.uid).count == 2 }
        await play(&clock)
        let gaps = await writer.finish()

        #expect(taps == 2, "the restart rebuilds")
        #expect(log.states(arm: 1) == [.waitingForApp, .recording], "waiting, then recording")
        #expect(gaps.isEmpty)
    }

    /// A7: the app does not run at the start: an empty tap records silence and the track waits;
    /// the app starts: a rebuild.
    @Test func anAppThatStartsLaterRebuildsFromTheEmptyTap() async throws {
        let writer = await writer([])
        await until("not waiting") { log.states(arm: 1).last == .waitingForApp }
        var clock = DeviceClock()
        await play(&clock)
        await change(writer, to: [41])
        await until("no rebuild") { hal.inputs(Self.uid).count == 2 }
        await play(&clock)
        await writer.finish()

        #expect(try stems() == ["take1-1-1", "take1-1-2"])
        #expect(log.states(arm: 1) == [.waitingForApp, .recording])
    }

    /// A8: the output of the app changes: a rebuild on the new output.
    @Test func anOutputChangeRebuilds() async throws {
        let writer = await writer([41])
        await change(writer, to: [41], output: "USBHeadset")
        await until("no rebuild") { hal.inputs(Self.uid).count == 2 }
        await writer.finish()

        #expect(taps == 2)
    }

    /// Code gate E3: no matched process reports an output, so the tap uses the default output.
    /// A change of the default output does not rebuild the tap (the key has no output).
    @Test func aDefaultOutputFlipWithNoReportedOutputKeepsTheTap() async throws {
        hal.setApp(Self.zoom, found([41], output: nil, main: "BuiltInSpeakerDevice"))
        let writer = DeviceWriter(
            device: InputDevice(
                uid: Self.uid, name: "zoom.us", nominalRate: 48_000, availableRates: [48_000...48_000],
                channelsPerBuffer: [1], latency: 0)!,
            tracks: [(arm: 1, channels: .mono(1))], files: TakeFiles(take: 1, folder: { [url = folder.url] in url }),
            hal: hal.hal, report: log.closure, silenceLimit: .seconds(60), firstRecordLimit: .seconds(60),
            app: Self.zoom)
        writer.start()
        await until("no first attach") { hal.inputs(Self.uid).count == 1 }
        await change(writer, to: [41], output: nil, main: "USBHeadset")
        await writer.finish()

        #expect(taps == 1, "a default output flip is no rebuild")
    }

    /// E3: the output is in the key only when a matched process reports it.
    @Test func theKeyHasOnlyAReportedOutput() throws {
        let process = AudioProcess(id: 41, bundleID: Self.zoom, path: "/Applications/zoom.us.app/Z", playing: true)
        let fallback = try #require(
            appFound(Self.zoom, processes: [process], output: "Speakers", reported: false, rate: 48_000, layout: .mono))
        #expect(fallback.key == AppKey(processes: [41], output: nil), "no reported output in the key")
        #expect(fallback.output == "Speakers", "the aggregate uses the default output")
        let reported = try #require(
            appFound(Self.zoom, processes: [process], output: "USBHeadset", reported: true, rate: 48_000, layout: .mono)
        )
        #expect(reported.key == AppKey(processes: [41], output: "USBHeadset"), "a reported output in the key")
    }

    /// Code gate 3 H1: no process reports an output, and the main sub-device of the aggregate
    /// leaves the device list: a rebuild on the new default output. Control: an event while it is
    /// there keeps the tap.
    @Test func aGoneMainSubDeviceRebuildsTheTap() async throws {
        let writer = await writer([41], output: nil)
        await change(writer, to: [41], output: nil)
        #expect(taps == 1, "control: the main sub-device is there")
        hal.removeOutput("BuiltInSpeakerDevice")
        await change(writer, to: [41], output: nil, main: "USBHeadset")
        await until("no rebuild") { hal.inputs(Self.uid).count == 2 }
        await writer.finish()

        #expect(taps == 2, "a gone main sub-device rebuilds")
    }

    /// A8: IsAlive false on the aggregate rebuilds, with no gap.
    @Test func isAliveFalseRebuildsWithNoGap() async throws {
        let writer = await writer([41])
        var clock = DeviceClock()
        await play(&clock)
        writer.post(.alive(false), from: hal.current(Self.uid))
        await until("no rebuild") { hal.inputs(Self.uid).count == 2 }
        await play(&clock)
        let gaps = await writer.finish()

        #expect(gaps.isEmpty, "a rebuild is no gap")
        #expect(try stems() == ["take1-1-1", "take1-1-2"])
        #expect(!log.states(arm: 1).contains(.deviceLost))
    }

    /// A7: a rebuild that throws makes the track lost with a gap; the 1 s retry brings it back.
    @Test func aRebuildThatThrowsLosesTheTrackAndTheRetryBringsItBack() async throws {
        hal.failAttach { uid, count in
            uid == "app:us.zoom.xos" && count == 2 ? .status(kAudioHardwareUnspecifiedError) : nil
        }
        let writer = await writer([41])
        await change(writer, to: [41, 42])
        await until("not lost") { log.states(arm: 1).contains(.deviceLost) }
        await until(limit: .seconds(3), "no retry") { hal.inputs(Self.uid).count == 2 }
        let gaps = await writer.finish()

        #expect(gaps == [1: .deviceLost], "a lost rebuild is a gap")
        #expect(log.states(arm: 1) == [.deviceLost, .recording])
    }

    /// The rebuild rule (W1, code gate 2 F2): a found process that the tap lacks, or a reported
    /// output that is not the main sub-device of the running aggregate (`out` here). No reported
    /// output, or the same device, keeps the tap.
    @Test(
        arguments: [
            ([41], [41], "out", false), ([41], [41, 42], "out", true), ([41, 42], [41], "out", false),
            ([41], [], "out", false), ([], [41], "out", true), ([41], [42], "out", true), ([41], [41], "usb", true),
            ([42, 41], [41, 42], "out", false), ([41], [41], nil, false),
        ] as [([AudioObjectID], [AudioObjectID], String?, Bool)])
    func theRebuildRule(current: [AudioObjectID], found: [AudioObjectID], output: String?, rebuild: Bool) {
        #expect(
            needsRebuild(AppKey(processes: current, output: "out"), AppKey(processes: found, output: output))
                == rebuild, "the rebuild rule")
    }

    /// F2: a process that starts or stops reporting the output that the aggregate already runs on
    /// keeps the tap; a reported other output rebuilds it.
    @Test func aReportOfTheTapOutputKeepsTheTap() async throws {
        hal.setApp(Self.zoom, found([41], output: nil, main: "BuiltInSpeakerDevice"))
        let writer = DeviceWriter(
            device: InputDevice(
                uid: Self.uid, name: "zoom.us", nominalRate: 48_000, availableRates: [48_000...48_000],
                channelsPerBuffer: [1], latency: 0)!,
            tracks: [(arm: 1, channels: .mono(1))], files: TakeFiles(take: 1, folder: { [url = folder.url] in url }),
            hal: hal.hal, report: log.closure, silenceLimit: .seconds(60), firstRecordLimit: .seconds(60),
            app: Self.zoom)
        writer.start()
        await until("no first attach") { hal.inputs(Self.uid).count == 1 }
        await change(writer, to: [41], output: "BuiltInSpeakerDevice")
        #expect(taps == 1, "nil to the same main: no rebuild")
        await change(writer, to: [41], output: nil, main: "BuiltInSpeakerDevice")
        #expect(taps == 1, "the same main to nil: no rebuild")
        await change(writer, to: [41], output: "BuiltInSpeakerDevice")
        #expect(taps == 1, "nil to the same main again: no rebuild")
        await change(writer, to: [41], output: "USBHeadset")
        await until("no rebuild") { hal.inputs(Self.uid).count == 2 }
        await writer.finish()

        #expect(taps == 2, "nil to another device: a rebuild")
    }
}
