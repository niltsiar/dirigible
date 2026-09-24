import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The lifetime of the writer and its rings (criterion 21), and a take in the studio with a lost
/// device (criteria 8 and 15). The fixture is in `DeviceEventTests`.
extension DeviceEventTests {
    // MARK: Criterion 21: writer and ring lifetime

    /// (a) A kept input of a failed detach does not keep the writer.
    @Test func aWriterWithAKeptInputGoesAwayAfterFinish() async throws {
        let hal = TestHAL([mic])
        hal.detach(returns: false)
        var writer: DeviceWriter? = writer(mic, hal)
        weak let gone = writer
        await until("no first attach") { hal.inputs("mic").count == 1 }
        writer?.post(.alive(false), from: hal.current("mic"))
        writer?.post(.devicesChanged, from: nil)
        await until("no back") { hal.inputs("mic").count == 2 }

        await writer?.finish()
        writer = nil

        await until("the writer is still alive after finish") { gone == nil }
    }

    /// (b) A late call into the ring of the first appearance never reaches the second segment.
    @Test func aLateCallOfAnOldAppearanceStaysOutOfTheNewSegment() async throws {
        let hal = TestHAL([mic])
        hal.detach(returns: false)
        let writer = writer(mic, hal)
        let input = SyntheticInput(hal, "mic")
        let late = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(run(&clock, 0.5))
        await input.wait()
        writer.post(.alive(false), from: hal.current("mic"))
        writer.post(.devicesChanged, from: nil)
        await until("no back") { hal.inputs("mic").count == 2 }
        let inputs = hal.inputs("mic")

        var lateClock = clock
        late.play(run(&lateClock, 0.1), pace: .ignoreRoom, into: inputs[0])
        clock.sampleTime = 0
        input.play(run(&clock, 0.5, value: 0.5), into: inputs[1])
        await late.wait()
        await input.wait()
        await writer.finish()

        #expect(try stems() == ["take1-1-1", "take1-1-2"])
        #expect(Set(try samples("take1-1-2")) == [0.5])
    }

    /// (c) Each failed detach keeps one input; after 8, the device stays lost. Control: a clean
    /// detach gives an attach for each of the 10 backs.
    @Test(arguments: [false, true])
    func eightKeptInputsStopTheAttaches(clean: Bool) async throws {
        let hal = TestHAL([mic])
        hal.detach(returns: clean)
        let writer = writer(mic, hal)
        await until("no first attach") { hal.inputs("mic").count == 1 }

        for cycle in 1...10 {
            writer.post(.alive(false), from: hal.inputs("mic").last)
            writer.post(.devicesChanged, from: nil)
            let expected = clean ? cycle + 1 : min(cycle + 1, 8)
            await until("cycle \(cycle): no back") { hal.inputs("mic").count == expected }
        }
        await writer.finish()

        #expect(hal.inputs("mic").count == (clean ? 11 : 8))
        #expect(log.states(arm: 1).last == (clean ? .recording : .deviceLost))
    }

    // MARK: Criterion 8 and 15: a take in the studio

    var box: InputDevice {
        InputDevice(
            uid: "box", name: "Box", nominalRate: 44_100, availableRates: [44_100...44_100], channelsPerBuffer: [2],
            latency: 0)!
    }

    /// A studio with `t1` on `first` channel 1 and `t2` on `box` channels 1 and 2.
    func studio(first uid: String, hal: TestHAL) async throws -> Studio {
        let url = folder.url.appending(path: "Show.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .stereo)
        try session.setRoute(Route(deviceUID: uid, channels: .mono(1)), track: "t1")
        try session.setRoute(Route(deviceUID: "box", channels: .stereo(1, 2)), track: "t2")
        try session.write(to: url)
        let studio = try await Studio.open(url)
        studio.environment = .test(hal)
        return studio
    }

    func clips(_ studio: Studio, _ track: TrackID) -> [Clip] {
        studio.session.track(track).map { Array($0.clips) } ?? []
    }

    @Test(arguments: [false, true])
    func aLostDeviceComesBackIntoANewSegment(lost: Bool) async throws {
        let hal = TestHAL([mic, box])
        let studio = try await studio(first: "mic", hal: hal)
        let writers = try studio.startTake(
            armed: ["t1", "t2"], devices: [mic, box], playhead: 0, hostTimeNanos: takeStart)
        let micInput = SyntheticInput(hal, "mic")
        let boxInput = SyntheticInput(hal, "box")
        var micClock = DeviceClock()
        var boxClock = DeviceClock(headerRate: 44_100, realRate: 44_100)

        boxInput.play(run(&boxClock, 1, layout: [2]))
        micInput.play(run(&micClock, 0.5))
        await micInput.wait()
        if lost {
            hal.set("mic", id: nil)
            studio.writer("mic")?.post(.alive(false), from: hal.current("mic"))
            await until("t1 is not lost") { studio.liveTracks["t1"]?.state == .deviceLost }
            #expect(studio.liveTracks["t2"]?.state == .recording)
            hal.set("mic", id: 1)
            studio.writer("mic")?.post(.devicesChanged, from: nil)
            micClock.sampleTime = 0
        }
        micInput.play(run(&micClock, 0.5))
        await micInput.wait()
        await boxInput.wait()
        await until("t1 is not recording") { studio.liveTracks["t1"]?.state == .recording }
        let gaps = await writers["mic"]?.finish()
        try await studio.stopRecording()

        #expect(gaps == (lost ? [1: .deviceLost] : [:]))
        #expect(clips(studio, "t1").map(\.id) == (lost ? ["take1-1-1", "take1-1-2"] : ["take1-1-1"]))
        #expect(clips(studio, "t2").map(\.id) == ["take1-2-1"])
        let length = try #require(clips(studio, "t2").first?.length.count)
        #expect(abs(length - 48_000) <= 1)
    }

    /// Criterion 15, second part: the real attach on a gone object loses that device only.
    /// Control: the same take with both devices on the test HAL records both.
    @Test(arguments: [false, true])
    func theRealAttachOnAGoneObjectLosesThatDeviceOnly(gone: Bool) async throws {
        let hal = TestHAL([mic, box])
        if gone {
            hal.set("mic", id: 0xDEAD)
            hal.attachLive("mic")
        }
        let studio = try await studio(first: "mic", hal: hal)
        _ = try studio.startTake(armed: ["t1", "t2"], devices: [mic, box], playhead: 0, hostTimeNanos: takeStart)
        let micInput = SyntheticInput(hal, "mic")
        let boxInput = SyntheticInput(hal, "box")
        var micClock = DeviceClock()
        var boxClock = DeviceClock(headerRate: 44_100, realRate: 44_100)

        boxInput.play(run(&boxClock, 0.5, layout: [2]))
        if gone {
            await until("t1 is not lost") { studio.liveTracks["t1"]?.state == .deviceLost }
        } else {
            micInput.play(run(&micClock, 0.5))
            await micInput.wait()
        }
        await boxInput.wait()
        try await studio.stopRecording()

        #expect(clips(studio, "t1").map(\.id) == (gone ? [] : ["take1-1-1"]))
        #expect(clips(studio, "t2").map(\.id) == ["take1-2-1"])
    }
}
