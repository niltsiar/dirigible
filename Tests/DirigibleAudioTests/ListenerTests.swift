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

    var starts: [Start] { lock.withLock { startList } }
    func stop(returns result: Bool) { lock.withLock { stopResult = result } }
    func failStarts(_ fails: Bool) { lock.withLock { startFails = fails } }
    /// Each device listener add fails, in the refresh of `SpeakerGuard`.
    func failWatch(_ fails: Bool) { lock.withLock { watchFails = fails } }
    /// The next stop waits in `gate` before it returns.
    func holdNextStop(in gate: Gate) { lock.withLock { stopGate = gate } }

    var output: ListenOutput {
        ListenOutput(
            watch: { [self] ring in
                let fails = lock.withLock { watchFails }
                return SpeakerGuard.refresh(
                    ring, output: { ListenOutput.offlineOutput }, subdevices: { _ in [] }, speakers: { _ in false },
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
        #expect(input.ring.device == input.id, "the ring knows its input device (the loopback check)")
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
