import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A silent, replaced, or lost device (criteria 19 and 20).
extension DeviceEventTests {
    // MARK: Criterion 19: a silent or replaced device

    /// The producers start before the attach and wait for it, so a test that waits on the main
    /// actor cannot hold the records back past the watchdog limit.
    @Test func theWatchdogLosesASilentDeviceAndTheRetryAttachesAgain() async throws {
        let hal = TestHAL([mic])
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(run(&clock, 0.5))
        clock.sampleTime = 0
        input.play(run(&clock, 0.5), attach: 2)
        let writer = writer(mic, hal, silenceLimit: .seconds(1))

        await until(limit: .seconds(5), "no second attach") { hal.inputs("mic").count >= 2 }
        await input.wait()
        let gaps = await writer.finish()

        #expect(try stems() == ["take1-1-1", "take1-1-2"])
        #expect(gaps == [1: .deviceLost])
        #expect(log.states(arm: 1).starts(with: [.deviceLost, .recording]))
    }

    /// Control of the watchdog: records with no pause keep the device. The producer sends for
    /// 60 s, longer than a full suite can hold the main actor, and `finish()` stops it.
    @Test func aDeviceWithNoPauseKeepsItsFirstAttach() async throws {
        let hal = TestHAL([mic])
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(run(&clock, 60), pace: .realTime)
        let writer = writer(mic, hal, silenceLimit: .seconds(1))

        try await Task.sleep(for: .seconds(2))
        let gaps = await writer.finish()
        await input.wait()

        #expect(hal.tries("mic").count == 1)
        #expect(try stems() == ["take1-1-1"])
        #expect(gaps == [:])
    }

    /// A device that starts its IO 3 s after the attach keeps its first attach: the first
    /// record of an appearance has a longer limit. Control: a first-record limit of 1 s (the
    /// watchdog limit) loses the device before its first record. The producer sends for 60 s,
    /// longer than a full suite can hold the main actor, and `finish()` stops it.
    @Test(arguments: [Duration.seconds(10), .seconds(1)])
    func aSlowStartKeepsTheFirstAttach(firstRecordLimit: Duration) async throws {
        let hal = TestHAL([mic])
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(run(&clock, 60), pace: .realTime, delay: .seconds(3))
        let writer = writer(mic, hal, silenceLimit: .seconds(1), firstRecordLimit: firstRecordLimit)
        let slow = firstRecordLimit > .seconds(3)

        await until(limit: .seconds(10), "no segment and no second attach") {
            (try? stems().isEmpty) == false || hal.tries("mic").count >= 2
        }
        let gaps = await writer.finish()
        await input.wait()

        // The control can try more than twice when the finish comes late.
        let tries = hal.tries("mic").count
        #expect(slow ? tries == 1 : tries >= 2, "tries \(tries)")
        #expect(try stems() == (slow ? ["take1-1-1"] : []))
        #expect(gaps == (slow ? [:] : [1: .deviceLost]))
    }

    @Test(arguments: [false, true])
    func aNewObjectIDIsALossAndABack(changed: Bool) async throws {
        let hal = TestHAL([])
        hal.set("mic", id: 7, device: mic)
        let writer = writer(mic, hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(run(&clock, 0.3))
        await input.wait()

        if changed { hal.set("mic", id: 8) }
        writer.post(.devicesChanged, from: nil)
        if changed {
            await until("no attach for object 8") { hal.inputs("mic").last?.id == 8 }
            clock.sampleTime = 0
        }
        input.play(run(&clock, 0.3))
        await input.wait()
        let gaps = await writer.finish()

        #expect(hal.inputs("mic").map(\.id) == (changed ? [7, 8] : [7]))
        #expect(try stems() == (changed ? ["take1-1-1", "take1-1-2"] : ["take1-1-1"]))
        #expect(gaps == (changed ? [1: .deviceLost] : [:]))
    }

    /// A late IsAlive event of the old appearance does nothing. Control: the same event from the
    /// current appearance is a loss, and the back gives a third segment.
    @Test(arguments: [false, true])
    func anEventFromAnOldAppearanceDoesNothing(fromCurrent: Bool) async throws {
        let hal = TestHAL([])
        hal.set("mic", id: 7, device: mic)
        let writer = writer(mic, hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(run(&clock, 0.3))
        await input.wait()
        hal.set("mic", id: 8)
        writer.post(.devicesChanged, from: nil)
        await until("no attach for object 8") { hal.inputs("mic").last?.id == 8 }
        clock.sampleTime = 0
        input.play(run(&clock, 0.3))
        await input.wait()

        let inputs = hal.inputs("mic")
        writer.post(.alive(false), from: fromCurrent ? inputs[1] : inputs[0])
        writer.post(.devicesChanged, from: nil)
        if fromCurrent {
            await until("no second attach for object 8") { hal.inputs("mic").count == 3 }
            clock.sampleTime = 0
        }
        input.play(run(&clock, 0.2))
        await input.wait()
        await writer.finish()

        #expect(hal.inputs("mic").map(\.id) == (fromCurrent ? [7, 8, 8] : [7, 8]))
        #expect(
            try stems() == (fromCurrent ? ["take1-1-1", "take1-1-2", "take1-1-3"] : ["take1-1-1", "take1-1-2"]))
    }

    // MARK: Criterion 20: retry while lost

    @Test(arguments: [false, true])
    func aLostDeviceTriesAgainEachSecond(comesBack: Bool) async throws {
        let hal = TestHAL([mic])
        let writer = writer(mic, hal)
        let input = SyntheticInput(hal, "mic")
        var clock = DeviceClock()
        input.play(run(&clock, 0.5))
        await input.wait()

        hal.set("mic", id: nil)
        writer.post(.alive(false), from: hal.current("mic"))
        await until("mic is not lost") { log.states(arm: 1) == [.deviceLost] }
        hal.failAttach { _, count in count == 2 || !comesBack ? .status(kAudioHardwareBadDeviceError) : nil }
        hal.set("mic", id: 1)
        if comesBack {
            await until(limit: .seconds(3), "mic did not come back") { log.states(arm: 1).last == .recording }
            clock.sampleTime = 0
            input.play(run(&clock, 0.5))
            await input.wait()
        } else {
            await until(limit: .seconds(2), "no retry") { hal.tries("mic").count >= 2 }
        }
        let gaps = await writer.finish()

        #expect(gaps == [1: .deviceLost])
        if comesBack {
            let tries = hal.tries("mic")
            #expect(tries.count == 3)
            #expect(tries[1].ring.context == tries[2].ring.context)
            #expect(try stems() == ["take1-1-1", "take1-1-2"])
        } else {
            #expect(log.states(arm: 1) == [.deviceLost])
            #expect(try stems() == ["take1-1-1"])
        }
    }
}
