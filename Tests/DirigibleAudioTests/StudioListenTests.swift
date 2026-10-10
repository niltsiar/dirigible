import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// `Studio.listen(to:)` before and during a take (decision 0044, plan slice 6). Every test uses
/// `CaptureEnvironment.test` with an offline listen output.
@MainActor
struct StudioListenTests {
    let busy = Duration.seconds(20)
    let duo = InputDevice(
        uid: "duo", name: "Duo", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [2],
        latency: 0)!
    let usb = InputDevice(
        uid: "usb", name: "USB", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!
    nonisolated static let zoom = "us.zoom.xos"

    /// `t1` on channel 1 of `duo`, `t2` on channel 2, `t3` on `usb`, and `t4` on an app.
    func package() async throws -> (folder: TemporaryFolder, url: URL) {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "Show.dirigible")
        try await offMainActor {
            var session = Session(sampleRate: 48_000)
            try session.addTrack("t1", name: "Host", layout: .mono)
            try session.addTrack("t2", name: "Guest", layout: .mono)
            try session.addTrack("t3", name: "Cohost", layout: .mono)
            try session.addTrack("t4", name: "Call", layout: .mono)
            try session.setRoute(Route.device(uid: "duo", channels: .mono(1)), track: "t1")
            try session.setRoute(Route.device(uid: "duo", channels: .mono(2)), track: "t2")
            try session.setRoute(Route.device(uid: "usb", channels: .mono(1)), track: "t3")
            try session.setRoute(.app(bundleID: Self.zoom), track: "t4")
            try session.write(to: url)
        }
        return (folder, url)
    }

    func open(_ url: URL, _ hal: TestHAL, access: MicrophoneAccess? = nil, output: ListenOutput = .offline())
        async throws -> Studio
    {
        let studio = try await Studio.open(url)
        studio.environment = .test(hal, access: access)
        studio.environment.listenOutput = output
        return studio
    }

    /// The listen input of attach number `attach` of `uid`.
    func input(_ hal: TestHAL, _ uid: String, attach: Int = 1) async -> ListenInput? {
        await until(limit: busy, "listen attach \(attach) of \(uid)") { hal.listenTries(uid).count >= attach }
        return hal.listenTries(uid).dropFirst(attach - 1).first
    }

    /// Pushes one block of 0.5 on each channel of the device of `input`, then pulls one block.
    /// True when the left output has sound.
    func sounds(_ input: ListenInput, width: Int) -> Bool {
        let signal = DeviceSignal(
            channels: Array(repeating: [Float](repeating: 0.5, count: 512), count: width), layout: [width])
        sendListen(signal, 0..<512, to: input)
        var played = Played()
        played.pull(input.ring, frames: 512)
        return played.left.contains { $0 != 0 }
    }

    func untilSound(_ input: ListenInput, width: Int, _ message: String) async {
        await until(limit: busy, message) { sounds(input, width: width) }
    }

    // MARK: A16 and A20

    @Test func aDeviceTrackListens() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo, usb])
        let studio = try await open(url, hal)
        try await studio.listen(to: ["t1"])
        let input = try #require(await input(hal, "duo"))
        await untilSound(input, width: 2, "A16: a device track plays its input")
        #expect(studio.quietListens.isEmpty, "A16: a playing track is not quiet")
        await studio.settle()
        _ = folder
    }

    @Test func anAppTrackHasNoListen() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo, usb])
        let studio = try await open(url, hal)
        try await studio.listen(to: ["t4"])
        #expect(studio.listeners.isEmpty, "G10: an app track has no Listener")
        try await studio.listen(to: ["t4", "t3"])
        #expect(Array(studio.listeners.keys) == ["usb"], "G10: the device track of the same request listens")
        await studio.settle()
        _ = folder
    }

    @Test func noAccessHoldsNoDevice() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo, usb])
        let studio = try await open(url, hal, access: .denied)
        await #expect(throws: StudioError.microphoneAccess(.denied)) { try await studio.listen(to: ["t1"]) }
        #expect(studio.listeners.isEmpty, "A20: no access holds no device")
        #expect(studio.listenRequest.isEmpty, "A20: the request is empty")
        #expect(hal.listenTries("duo").isEmpty, "A20: no listen attach")
        await studio.settle()
        _ = folder
    }

    // MARK: A8 and A24

    /// The off of `usb` holds its unit stop. A later off of `duo` waits for that turn, but `duo`
    /// plays zeros at once.
    @Test func offSilencesAtOnce() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo, usb])
        let output = TestOutput()
        let studio = try await open(url, hal, output: output.output)
        try await studio.listen(to: ["t1", "t3"])
        let duoInput = try #require(await input(hal, "duo"))
        await untilSound(duoInput, width: 2, "duo plays")
        let gate = Gate(limit: nil)
        defer { gate.open() }
        output.holdNextStop(in: gate)
        let first = Task { try await studio.listen(to: ["t1"]) }
        await gate.entered()
        let second = Task { try await studio.listen(to: []) }
        await until(limit: busy, "A8: an off plays zeros before its turn") { !sounds(duoInput, width: 2) }
        #expect(studio.listenTurns.waiters >= 1, "A8: the off waits for the held turn")
        gate.open()
        try await first.value
        try await second.value
        await studio.settle()
        _ = folder
    }

    @Test func anotherDeviceKeepsPlaying() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo, usb])
        let studio = try await open(url, hal)
        try await studio.listen(to: ["t1", "t3"])
        let duoInput = try #require(await input(hal, "duo"))
        let usbInput = try #require(await input(hal, "usb"))
        await untilSound(usbInput, width: 1, "usb plays")
        try await studio.listen(to: ["t1"])
        // A clean off frees the ring bytes of usb, so the test pushes no more into it.
        #expect(hal.listenDetaches("usb") == 1, "A8: the device that left is detached")
        await untilSound(duoInput, width: 2, "A8: the other device keeps playing")
        #expect(hal.listenDetaches("duo") == 0, "A8: the other device is not detached")
        await studio.settle()
        _ = folder
    }

    @Test func settleStopsTheOutput() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo, usb])
        let studio = try await open(url, hal)
        try await studio.listen(to: ["t1"])
        let input = try #require(await input(hal, "duo"))
        await untilSound(input, width: 2, "duo plays")
        await studio.settle()
        #expect(hal.listenDetaches("duo") == 1, "A24: settle detaches the Listener")
        #expect(studio.listeners.isEmpty && studio.listenRequest.isEmpty, "A24: settle empties the request")
        _ = folder
    }

    // MARK: The quiet text

    @Test func aQuietListenerMarksItsTracks() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo, usb])
        let output = TestOutput()
        output.failStarts(true)
        let studio = try await open(url, hal, output: output.output)
        try await studio.listen(to: ["t1", "t2", "t3"])
        await until(limit: busy, "a failed output marks its tracks") { studio.quietListens == ["t1", "t2", "t3"] }
        output.failStarts(false)
        await until(limit: busy, "a playing Listener clears its tracks") { studio.quietListens.isEmpty }
        await studio.settle()
        _ = folder
    }

    @Test func offClearsTheQuietText() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo, usb])
        let output = TestOutput()
        output.failStarts(true)
        let studio = try await open(url, hal, output: output.output)
        try await studio.listen(to: ["t1", "t2"])
        await until(limit: busy, "a failed output marks its tracks") { studio.quietListens == ["t1", "t2"] }
        try await studio.listen(to: ["t1"])
        #expect(studio.quietListens == ["t1"], "G20: the track that left is not quiet")
        try await studio.listen(to: [])
        #expect(studio.quietListens.isEmpty, "G20: off clears the quiet text")
        await studio.settle()
        _ = folder
    }

    @Test func aLateReportOfAReleasedListenerIsIgnored() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo, usb])
        let studio = try await open(url, hal)
        try await studio.listen(to: ["t1"])
        let old = try #require(studio.listeners["duo"]?.number)
        try await studio.listen(to: [])
        try await studio.listen(to: ["t1"])
        let new = try #require(studio.listeners["duo"]?.number)
        _ = try #require(await input(hal, "duo", attach: 2))
        studio.applyListen(.quiet, number: old, uid: "duo")
        #expect(studio.quietListens.isEmpty, "G20: a late report of a released Listener changes nothing")
        studio.applyListen(.quiet, number: new, uid: "duo")
        #expect(studio.quietListens == ["t1"], "G20: a report of the current Listener applies")
        await studio.settle()
        _ = folder
    }

    // MARK: A7, A17, A18, A19

    /// A7: the Listener plays across the begin, the hand-over, the stop, and the come back of a
    /// take on the same device, with no detach and no new appearance. Control: a request change
    /// during the take that removes the device detaches it.
    @Test func theListenerPlaysAcrossTheHandOver() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo, usb])
        let studio = try await open(url, hal)
        try await studio.monitor(armed: ["t1"])
        try await studio.listen(to: ["t1"])
        let input = try #require(await input(hal, "duo"))
        await untilSound(input, width: 2, "duo plays before the take")
        // A detach frees the ring bytes, so the test pushes only while no detach came.
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        let playsInTake = hal.listenDetaches("duo") == 0 && sounds(input, width: 2)
        #expect(playsInTake, "A7: the Listener plays after the hand-over, with no detach")
        try await studio.stopRecording()
        await until(limit: busy, "the monitor comes back") { studio.liveTracks["t1"]?.state == .monitoring }
        let playsAfter = hal.listenDetaches("duo") == 0 && sounds(input, width: 2)
        #expect(playsAfter, "A7: the Listener plays after the stop and the come back, with no detach")
        #expect(hal.listenTries("duo").count == 1, "G14: no take step attaches the Listener again")
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        try await studio.listen(to: [])
        #expect(hal.listenDetaches("duo") == 1, "A7 control: an off during a take detaches")
        try await studio.stopRecording()
        await studio.settle()
        _ = folder
    }

    /// A18: an on and an off do not wait for a held finalize.
    @Test func aMonitorChangeDoesNotWaitForAFinalize() async throws {
        let (folder, url) = try await package()
        let hal = TestHAL([duo, usb])
        let gate = AsyncGate()
        let studio = try await Studio.open(url)
        studio.environment = .test(hal, beforeFinalize: { await gate.wait() })
        try await studio.startRecording(armed: ["t1"], playhead: 0)
        let stop = Task { try await studio.stopRecording() }
        await gate.entered()
        try await studio.listen(to: ["t3"])
        _ = try #require(await input(hal, "usb"))
        try await studio.listen(to: [])
        #expect(hal.listenDetaches("usb") == 1, "A18: the off runs during the finalize")
        #expect(studio.transport == .finalizing(take: 1), "A18: the finalize is still held")
        gate.open()
        try await stop.value
        await studio.settle()
        _ = folder
    }

    /// A19: a play start and stop do not touch the Listener.
    @Test func theListenerPlaysWithPlayback() async throws {
        let package = try MixPackage()
        try package.addFile("f1", channels: [ramp(frames: 100_000)])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: 48_000)
        try package.session.setRoute(Route.device(uid: "usb", channels: .mono(1)), track: "t1")
        try package.session.write(to: package.url)
        let hal = TestHAL([usb])
        let studio = try await open(package.url, hal)
        try await studio.listen(to: ["t1"])
        let input = try #require(await input(hal, "usb"))
        await untilSound(input, width: 1, "usb plays")
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        _ = await studio.renderOffline(frames: 9_600)
        let running = await studio.play.player?.reading().running
        #expect(running == true, "A19: the play started")
        #expect(sounds(input, width: 1), "A19: the Listener plays during the play")
        await studio.perform(.playStop)
        #expect(sounds(input, width: 1), "A19: the Listener plays after the stop")
        #expect(hal.listenDetaches("usb") == 0 && hal.listenTries("usb").count == 1, "A19: no restart")
        await studio.settle()
    }

    /// A17: an on and an off during a take leave the take file with the same bytes as a take
    /// with no listen.
    @Test func theMonitorWorksDuringATake() async throws {
        let plain = try await timedTake(listen: false)
        let listened = try await timedTake(listen: true)
        #expect(plain.count > 90_000, "A17: the take has its frames")
        #expect(plain == listened, "A17: the listen does not change the take file")
    }

    /// The bytes of the take file of `t3` (on `usb`) of a 2 s take of constant records.
    func timedTake(listen: Bool) async throws -> Data {
        let (folder, url) = try await package()
        let hal = TestHAL([duo, usb])
        let studio = try await open(url, hal)
        let producer = SyntheticInput(hal, "usb")
        var clock = DeviceClock(hostNanos: Double(takeStart) - 500_000_000)
        var generator = SeededGenerator(seed: 1)
        producer.play(clock.run(seconds: 3, using: &generator), takeStartIn: url)
        let toggle = Task { @MainActor in
            guard listen else { return }
            await until(limit: busy, "the take writer attaches") { hal.calls.contains("attach usb") }
            try? await studio.listen(to: ["t3"])
            _ = await input(hal, "usb")
            try? await studio.listen(to: [])
        }
        _ = try await studio.record(armed: ["t3"], playhead: 0, for: .seconds(2))
        await toggle.value
        await producer.wait()
        if listen {
            // The order of the HAL calls proves that the on and the off came during the take.
            let calls = hal.calls
            let order = ["attach usb", "listen usb", "unlisten usb", "detach usb"].map { calls.firstIndex(of: $0) }
            #expect(order.allSatisfy { $0 != nil } && order == order.sorted { ($0 ?? 0) < ($1 ?? 0) }, "A17: \(calls)")
        }
        let clip = try #require(studio.session.track("t3")?.clips.first)
        let path = try #require(studio.session.files[clip.file]?.path)
        let data = try Data(contentsOf: url.appending(path: "Clips").appending(path: path))
        await studio.settle()
        _ = folder
        return data
    }
}
