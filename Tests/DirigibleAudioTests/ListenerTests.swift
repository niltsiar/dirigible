import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The test `ListenOutput`: each start with the ring, the rate, and the fill before the start;
/// a stop result, a held stop, and a start that throws. The flag is false (headphones).
final class TestOutput: @unchecked Sendable {
    struct Start {
        let ring: ListenRing
        let rate: Double
        let fillBefore: Int
    }

    private let lock = NSLock()
    private var startList: [Start] = []
    private var stopResult = true
    private var startFails = false
    private var watchFails = false
    private var stopGate: Gate?
    private var outputID = ListenOutput.offlineOutput

    var starts: [Start] { lock.withLock { startList } }
    func stop(returns result: Bool) { lock.withLock { stopResult = result } }
    func failStarts(_ fails: Bool) { lock.withLock { startFails = fails } }
    /// Each device listener add fails, in the refresh of `SpeakerGuard`.
    func failWatch(_ fails: Bool) { lock.withLock { watchFails = fails } }
    /// The default output is the device with `id`.
    func setOutput(_ id: AudioObjectID) { lock.withLock { outputID = id } }
    /// The next stop waits in `gate` before it returns.
    func holdNextStop(in gate: Gate) { lock.withLock { stopGate = gate } }

    var output: ListenOutput {
        ListenOutput(
            watch: { [self] ring in
                let (fails, id) = lock.withLock { (watchFails, outputID) }
                return SpeakerGuard.refresh(
                    ring, output: { id }, subdevices: { _ in [] }, speakers: { _ in false },
                    add: { _, _, _ in !fails })
            },
            unwatch: { SpeakerGuard.close($0, remove: { _ in }) },
            start: { [self] ring, rate, inputBlock throws(HALError) in
                guard !lock.withLock({ startFails }) else { throw .status(kAudioHardwareUnspecifiedError) }
                let fill = ring.available
                ring.prepare(rate: rate, inputBlock: inputBlock, pull: 512)
                lock.withLock { startList.append(Start(ring: ring, rate: rate, fillBefore: fill)) }
                return { [self] in
                    lock.withLock { stopGate }?.waitOnce()
                    return lock.withLock { stopResult }
                }
            })
    }
}

/// The reports of one Listener, in order.
final class ListenReports: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [ListenReport] = []
    var all: [ListenReport] { lock.withLock { list } }
    func add(_ report: ListenReport) { lock.withLock { list.append(report) } }
}

/// Calls the listen IOProc once with the frames `range` of `signal`, as the HAL does.
func sendListen(_ signal: DeviceSignal, _ range: Range<Int>, to input: ListenInput) {
    withPaddedList(signal, range) { list in
        var time = AudioTimeStamp()
        var output = AudioBufferList()
        withUnsafePointer(to: &time) { time in
            _ = ListenRing.ioProc(1, time, list, time, &output, time, input.ring.context)
        }
    }
}

/// A5, A8 off, A9, A21, and the memory rules of the Listener of one device (plan slice 5).
@MainActor struct ListenerTests {
    let mic = InputDevice(
        uid: "mic", name: "Mic", nominalRate: 48_000, availableRates: [44_100...48_000], channelsPerBuffer: [1],
        latency: 0)!
    let hal: TestHAL
    let output = TestOutput()
    let reports = ListenReports()

    init() { hal = TestHAL([mic]) }

    func listener(retry: Duration = .milliseconds(20), keepLimit: Int = Listener.keepLimit) -> Listener {
        let reports = reports
        return Listener(
            uid: "mic", map: ChannelMap(routes: [.mono(1)]), hal: hal.hal, output: output.output,
            report: { reports.add($0) }, retryInterval: retry, keepLimit: keepLimit)
    }

    /// The current listen input, after the Listener reported `reportCount` reports.
    func input(after reportCount: [ListenReport]) async -> ListenInput? {
        await until(limit: .seconds(10), "the reports are \(reportCount)") { reports.all == reportCount }
        return hal.listenTries("mic").last
    }

    @Test func aListenerPlaysThroughTheOfflineOutput() async throws {
        let listener = listener()
        listener.start()
        let input = try #require(await input(after: [.playing]))
        let signal = DeviceSignal.sines(seconds: 1, layout: [1])
        var played = Played()
        for start in stride(from: 0, to: 47_616, by: 512) {
            sendListen(signal, start..<start + 512, to: input)
            played.pull(input.ring, frames: 512)
        }
        let plays = playsDelayed(played.left, signal.channels[0])
        #expect(plays, "the offline output plays the listen IOProc input")
        await listener.off()
    }

    /// A21: the device is absent at the start, so the Listener waits; it plays after the 1 s
    /// retry when the device comes back.
    @Test func aMissingDeviceComesBack() async throws {
        hal.set("mic", id: nil)
        let listener = listener(retry: .seconds(1))
        listener.start()
        await until(limit: .seconds(10), "an absent device waits") { reports.all == [.quiet] }
        #expect(hal.listenTries("mic").isEmpty, "A21: an absent device gets no attach")
        hal.set("mic", id: 1)
        _ = try #require(await input(after: [.quiet, .playing]))
        #expect(hal.listenTries("mic").count == 1, "A21: the retry attaches once")
        await listener.off()
    }

    /// A5: a rate change makes a new unit at the new input rate.
    @Test func aRateChangeRestartsTheOutput() async throws {
        let listener = listener()
        listener.start()
        let input = try #require(await input(after: [.playing]))
        listener.post(.rate(44_100), from: input)
        await until(limit: .seconds(10), "a rate change restarts the output") { output.starts.count == 2 }
        #expect(output.starts.map(\.rate) == [48_000, 44_100], "A5: the new unit has the new rate")
        #expect(reports.all == [.playing], "A5: the Listener plays across the restart")
        await listener.off()
    }

    @Test func aRateChangeFlushesAfterACleanStop() async throws {
        let listener = listener()
        listener.start()
        let input = try #require(await input(after: [.playing]))
        let signal = DeviceSignal.sines(seconds: 1, layout: [1])
        for start in stride(from: 0, to: 2048, by: 512) { sendListen(signal, start..<start + 512, to: input) }
        listener.post(.rate(44_100), from: input)
        await until(limit: .seconds(10), "a rate change restarts the output") { output.starts.count == 2 }
        #expect(output.starts.last?.fillBefore == 2048, "G18: the ring had frames at the restart")
        #expect(input.ring.available == 0, "G18: a clean stop flushes the ring")
        await listener.off()
    }

    /// A failed stop keeps the ring with its frames, and the Listener waits.
    @Test func aFailedStopDoesNotFlush() async throws {
        output.stop(returns: false)
        let listener = listener(retry: .seconds(3600))
        listener.start()
        let input = try #require(await input(after: [.playing]))
        let signal = DeviceSignal.sines(seconds: 1, layout: [1])
        for start in stride(from: 0, to: 2048, by: 512) { sendListen(signal, start..<start + 512, to: input) }
        listener.post(.rate(44_100), from: input)
        await until(limit: .seconds(10), "a failed stop waits") { reports.all == [.playing, .quiet] }
        #expect(input.ring.available == 2048, "G18: a failed stop does not flush")
        #expect(output.starts.count == 1, "G18: no unit starts after a failed stop")
        #expect(await listener.counts() == Listener.Counts(kept: 1, freed: 0, retries: 1), "G18: the ring is kept")
        #expect(input.ring.speakers, "a unit that did not stop plays zeros from its kept ring")
        await listener.off()
    }

    /// The output start throws: the IOProc is detached, the Listener waits, and it tries again.
    @Test func anOutputStartFailureWaits() async throws {
        output.failStarts(true)
        // No keep limit: a held main actor must not let 64 failed starts end the retry.
        let listener = listener(keepLimit: .max)
        listener.start()
        await until(limit: .seconds(10), "a failed output start retries") { hal.listenTries("mic").count >= 2 }
        #expect(reports.all == [.quiet], "a failed output start is quiet")
        #expect(hal.listenDetaches("mic") >= 1, "a failed output start detaches the IOProc")
        output.failStarts(false)
        await until(limit: .seconds(10), "the retry plays") { reports.all == [.quiet, .playing] }
        await listener.off()
    }

    /// A failed speaker listener add is quiet: the Listener detaches and tries again, and the
    /// retry plays (code gate round 1, item 3).
    @Test func aFailedSpeakerWatchWaits() async throws {
        output.failWatch(true)
        let listener = listener(keepLimit: .max)
        listener.start()
        await until(limit: .seconds(10), "a failed watch retries") { hal.listenTries("mic").count >= 2 }
        #expect(reports.all == [.quiet], "a failed watch is quiet")
        #expect(output.starts.isEmpty, "no unit starts after a failed watch")
        #expect(hal.listenDetaches("mic") >= 1, "a failed watch detaches the IOProc")
        output.failWatch(false)
        await until(limit: .seconds(10), "the retry plays") { reports.all == [.quiet, .playing] }
        await listener.off()
    }

    /// A duplex hardware device (a USB interface with a headphone out) plays its input in its
    /// own output (code gate round 2, item 1).
    @Test func aDuplexHardwareDevicePlaysInItsOwnOutput() async throws {
        output.setOutput(1)
        let listener = listener()
        listener.start()
        let input = try #require(await input(after: [.playing]))
        #expect(input.id == 1 && !input.ring.speakers, "a duplex hardware device plays in its own output")
        await listener.off()
    }

    /// A virtual device (a loopback device) that is also the output plays zeros, because the
    /// monitor would feed its own input (code gate round 2, item 1).
    @Test func aVirtualDeviceInItsOwnOutputIsALoopback() async throws {
        hal.setVirtual("mic")
        output.setOutput(1)
        let listener = listener()
        listener.start()
        let input = try #require(await input(after: [.loopback]))
        #expect(input.ring.speakers, "a virtual device in its own output plays zeros")
        output.setOutput(5)
        _ = output.output.watch(input.ring)
        #expect(!input.ring.speakers, "a virtual device plays in another output")
        await until(limit: .seconds(10), "the refresh reports the play") { reports.all == [.loopback, .playing] }
        await listener.off()
    }

    /// An aggregate input with a virtual subdevice plays zeros when the output is that subdevice:
    /// the monitor would feed its own input (code review of a28d7ab9, item 1). Device 40 is USB,
    /// 41 is virtual. Control in the same test: the USB subdevice as the output plays.
    @Test func anAggregateInputMutesOnItsVirtualSubdevice() async throws {
        hal.setAggregate("mic", subdevices: [40, 41], virtual: [41])
        output.setOutput(41)
        let listener = listener()
        listener.start()
        let input = try #require(await input(after: [.loopback]), "the Listener reports the loopback")
        #expect(input.ring.speakers, "the virtual subdevice as the output plays zeros")
        output.setOutput(40)
        _ = output.output.watch(input.ring)
        #expect(!input.ring.speakers, "the USB subdevice as the output plays")
        await until(limit: .seconds(10), "the refresh reports the play") { reports.all == [.loopback, .playing] }
        output.setOutput(41)
        _ = output.output.watch(input.ring)
        await until(limit: .seconds(10), "a refresh reports the loopback again") {
            reports.all == [.loopback, .playing, .loopback]
        }
        await listener.off()
    }

    /// A change of the active subdevices of an aggregate input mutes the ring at once and starts
    /// again, so the new appearance reads the loopback set again (code gate round 1, item 2).
    @Test func aSubdeviceChangeReadsTheLoopbackAgain() async throws {
        hal.setAggregate("mic", subdevices: [40, 41], virtual: [])
        output.setOutput(41)
        let listener = listener()
        listener.start()
        let first = try #require(await input(after: [.playing]))
        #expect(!first.ring.speakers, "no virtual subdevice: the monitor plays")
        hal.setAggregate("mic", subdevices: [40, 41], virtual: [41])
        listener.post(.subdevices, from: first)
        #expect(first.ring.speakers, "the ring plays zeros at once")
        await until(limit: .seconds(10), "a second appearance reports the loopback") {
            hal.listenTries("mic").count == 2 && reports.all == [.playing, .loopback]
        }
        #expect(hal.listenTries("mic").last?.ring.speakers == true, "the new ring plays zeros")
        await listener.off()
    }

    /// A subdevice change at the keep limit starts no new appearance and reports quiet, so the
    /// header does not show a monitor that plays (code gate round 2, item 2).
    @Test func aSubdeviceChangeAtTheKeepLimitIsQuiet() async throws {
        hal.setAggregate("mic", subdevices: [40, 41], virtual: [])
        output.setOutput(41)
        let listener = listener(keepLimit: 1)
        listener.start()
        let first = try #require(await input(after: [.playing]))
        hal.setAggregate("mic", subdevices: [40, 41], virtual: [41])
        listener.post(.subdevices, from: first)
        await until(limit: .seconds(10), "the Listener reports quiet") { reports.all == [.playing, .quiet] }
        #expect(hal.listenTries("mic").count == 1, "no appearance after the keep limit")
        await listener.off()
    }

    /// A subdevice change between the loopback read and the listener add has no listener call.
    /// The Listener reads the set again after the attach, so it never plays with the old set: the
    /// first appearance fails, and the retry reads the new set (code gate round 2, item 3).
    @Test func aSubdeviceChangeBeforeTheAddReadsTheLoopbackAgain() async throws {
        hal.setAggregate("mic", subdevices: [40, 41], virtual: [])
        hal.setAggregateAtAttach("mic", subdevices: [40, 41], virtual: [41])
        output.setOutput(41)
        let listener = listener()
        listener.start()
        await until(limit: .seconds(10), "the retry reports the loopback") { reports.all == [.quiet, .loopback] }
        #expect(hal.listenTries("mic").count == 2, "the first appearance fails, and the retry plays zeros")
        #expect(output.starts.count == 1, "only the appearance with the new set starts the unit")
        await listener.off()
    }

    /// A failed transport read is unknown, so every output counts as a loopback (fail closed).
    /// The read is a HAL property read of an object that does not exist, with no IO.
    @Test func aFailedTransportReadIsUnknown() {
        #expect(DeviceHAL.live.loopback(AudioObjectID(kAudioObjectUnknown)) == .unknown, "a failed read is unknown")
        #expect(Loopback.unknown.feeds([5]), "an unknown loopback feeds every output")
    }

    /// An aggregate under itself, directly or in a cycle, is unknown, with no endless recursion
    /// (code review of a28d7ab9, item 2). Device 10 lists itself; 11 and 12 list each other.
    @Test func aCycleOfAggregatesIsUnknown() {
        let subdevices: [AudioObjectID: [AudioObjectID]] = [10: [10], 11: [12], 12: [11]]
        let loopback = { (device: AudioObjectID) in
            loopbackDevices(
                device, transport: { _ in kAudioDeviceTransportTypeAggregate }, subdevices: { subdevices[$0] })
        }
        #expect(loopback(10) == .unknown, "an aggregate in its own list is unknown")
        #expect(loopback(11) == .unknown, "a cycle of two aggregates is unknown")
    }

    /// The loopback devices of an aggregate (transport 'grup', or 'fgrp' for an auto-aggregate):
    /// the virtual devices under it and the aggregate itself; unknown when a read fails (fail
    /// closed). Device 2 is virtual, 3 is USB, 4 is an aggregate of 3 and 2, 5 is an aggregate
    /// of 3, 6 is an aggregate with no read, 7 is an auto-aggregate of 2, 8 is an
    /// auto-aggregate with no read, and 9 is an aggregate of 4 and 3.
    @Test func anAggregateGivesItsVirtualLeaves() {
        let transports: [AudioObjectID: UInt32] = [
            2: kAudioDeviceTransportTypeVirtual, 3: kAudioDeviceTransportTypeUSB,
            4: kAudioDeviceTransportTypeAggregate, 5: kAudioDeviceTransportTypeAggregate,
            6: kAudioDeviceTransportTypeAggregate, 7: kAudioDeviceTransportTypeAutoAggregate,
            8: kAudioDeviceTransportTypeAutoAggregate, 9: kAudioDeviceTransportTypeAggregate,
        ]
        let subdevices: [AudioObjectID: [AudioObjectID]] = [4: [3, 2], 5: [3], 7: [2], 9: [4, 3]]
        let loopback = { (device: AudioObjectID) in
            loopbackDevices(device, transport: { transports[$0] }, subdevices: { subdevices[$0] })
        }
        #expect(loopback(2) == .devices([2]), "a virtual device is its own loopback")
        #expect(loopback(3) == .devices([]), "a USB device is no loopback")
        #expect(loopback(4) == .devices([4, 2]), "an aggregate gives its virtual subdevice")
        #expect(loopback(5) == .devices([]), "an aggregate of hardware devices is no loopback")
        #expect(loopback(6) == .unknown, "an aggregate with a failed subdevice read is unknown")
        #expect(loopback(7) == .devices([7, 2]), "an auto-aggregate gives its virtual subdevice")
        #expect(loopback(8) == .unknown, "an auto-aggregate with a failed subdevice read is unknown")
        #expect(loopback(9) == .devices([9, 4, 2]), "a nested aggregate gives its virtual leaf")
    }

    /// The rate of the attach, read after its listener adds, wins over the rate of the lookup: a
    /// change between the two has no listener call (code gate round 1, item 7).
    @Test func theOutputStartsAtTheRateOfTheAttach() async throws {
        hal.listenRate("mic", 44_100)
        let listener = listener()
        listener.start()
        _ = try #require(await input(after: [.playing]))
        #expect(output.starts.last?.rate == 44_100, "the unit starts at the rate that the attach read")
        await listener.off()
    }

    @Test func aFailedDetachKeepsTheRing() async throws {
        hal.listenDetach(returns: false)
        let listener = listener()
        listener.start()
        _ = try #require(await input(after: [.playing]))
        await listener.off()
        #expect(await listener.counts() == Listener.Counts(kept: 1, freed: 0), "G8: a failed detach keeps the ring")
    }

    @Test func aCleanOffFreesTheRing() async throws {
        let listener = listener()
        listener.start()
        _ = try #require(await input(after: [.playing]))
        await listener.off()
        #expect(await listener.counts() == Listener.Counts(kept: 1, freed: 1), "G8: a clean off frees the ring")
        #expect(hal.listenDetaches("mic") == 1, "the off detaches the IOProc")
        #expect(reports.all == [.playing], "no report after the off")
    }

    /// Each attach that fails after its IOProc existed keeps an appearance. At 64 the Listener
    /// tries no more.
    @Test func theKeepLimitStopsRetrying() async throws {
        hal.failListen { _, _ in .undone(kAudioHardwareUnspecifiedError) }
        let listener = listener(retry: .milliseconds(1))
        listener.start()
        await until(limit: .seconds(10), "64 kept appearances") { hal.listenTries("mic").count >= 64 }
        // The counts run on the queue after the 64th try. Each try after the first needs a
        // scheduled retry, so 63 retries prove that no 65th try can come.
        #expect(
            await listener.counts() == Listener.Counts(kept: 64, freed: 64, retries: 63),
            "G9: 64 kept appearances, and no retry after the 64th")
        #expect(hal.listenTries("mic").count == 64, "G9: no try after 64 kept appearances")
        #expect(reports.all == [.quiet], "G9: the Listener is quiet")
        await listener.off()
    }

    /// A8: the off mutes the ring before the unit stop: zeros while the stop is held.
    @Test func offMutesBeforeTheStop() async throws {
        let listener = listener()
        listener.start()
        let input = try #require(await input(after: [.playing]))
        let signal = DeviceSignal.sines(seconds: 1, layout: [1])
        var played = Played()
        for start in stride(from: 0, to: 24_064, by: 512) {
            sendListen(signal, start..<start + 512, to: input)
            played.pull(input.ring, frames: 512)
        }
        #expect(played.left.suffix(512).contains { $0 != 0 }, "A8: the ring plays before the off")
        let gate = Gate(limit: nil)
        defer { gate.open() }
        output.holdNextStop(in: gate)
        let off = Task { await listener.off() }
        await gate.entered()
        sendListen(signal, 24_064..<24_576, to: input)
        var held = Played()
        held.pull(input.ring, frames: 512)
        #expect(held.left.allSatisfy { $0 == 0 }, "A8: zeros while the stop is held")
        gate.open()
        await off.value
    }

    @Test func theReportFollowsThePhase() async throws {
        let listener = listener()
        listener.start()
        let input = try #require(await input(after: [.playing]))
        listener.post(.alive(false), from: input)
        await until(limit: .seconds(10), "a lost device waits, then plays again") {
            reports.all == [.playing, .quiet, .playing]
        }
        #expect(hal.listenTries("mic").count == 2, "the come back attaches again")
        await listener.off()
    }

    enum Failure: CaseIterable { case stop, detach }

    /// A retry after a failed stop or a failed detach makes a new ring: the new unit reads only
    /// the new ring, and the old one is kept.
    @Test(arguments: Failure.allCases)
    func aRetryAfterAFailedStopUsesANewRing(_ failure: Failure) async throws {
        if failure == .stop { output.stop(returns: false) } else { hal.listenDetach(returns: false) }
        let listener = listener()
        listener.start()
        let first = try #require(await input(after: [.playing]))
        listener.post(.alive(false), from: first)
        let second = try #require(await input(after: [.playing, .quiet, .playing]))
        #expect(second.ring.context != first.ring.context, "G21: the retry has a new ring")
        #expect(output.starts.last?.ring.context == second.ring.context, "G21: the new unit reads the new ring")
        #expect(await listener.counts() == Listener.Counts(kept: 1, freed: 0, retries: 1), "G21: the old ring is kept")
        output.stop(returns: true)
        hal.listenDetach(returns: true)
        await listener.off()
    }
}
