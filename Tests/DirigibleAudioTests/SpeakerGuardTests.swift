import CoreAudio
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// The data source listeners of a fake HAL: `add` inserts the device, and `remove` removes it.
/// `beforeAdd` runs once, inside the first add, with no lock held.
private final class FakeListeners: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: Set<AudioObjectID> = []
    private var beforeAdd: (() -> Void)?

    init(beforeAdd: (() -> Void)? = nil) { self.beforeAdd = beforeAdd }

    var listening: Set<AudioObjectID> { lock.withLock { devices } }

    func add(_ device: AudioObjectID) -> Bool {
        let hook = lock.withLock { () -> (() -> Void)? in
            defer { beforeAdd = nil }
            return beforeAdd
        }
        hook?()
        lock.withLock { _ = devices.insert(device) }
        return true
    }

    func remove(_ device: AudioObjectID) { lock.withLock { _ = devices.remove(device) } }

    /// The watch of `ring` on this HAL.
    func watch(_ ring: ListenRing) -> (AudioObjectID) -> Void {
        { SpeakerGuard.watch(ring, $0, add: self.add, remove: self.remove) }
    }
}

private let builtIn = kAudioDeviceTransportTypeBuiltIn
private let internalSpeakers: UInt32 = 0x6973_706B  // 'ispk'
private let headphones: UInt32 = 0x6864_706E  // 'hdpn'

/// A refresh of `ring` with one default output and one synthetic data source.
private func refreshOn(_ ring: ListenRing, output: AudioObjectID? = 7, dataSource: UInt32?) {
    SpeakerGuard.refresh(
        ring, output: { output }, watch: { _ in },
        speakers: { _ in isBuiltInSpeakers(transport: builtIn, dataSource: dataSource) })
}

/// Runs `body` on a thread outside the concurrency pool and returns when it ends.
private func onThread(_ body: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { done in
        Thread.detachNewThread {
            body()
            done.resume()
        }
    }
}

/// A10 core and A11: the speaker flag of a listen ring (plan slice 4).
struct SpeakerGuardTests {
    struct Case: Sendable {
        let transport: UInt32?
        let dataSource: UInt32?
        let speakers: Bool
    }

    static let cases = [
        Case(transport: builtIn, dataSource: internalSpeakers, speakers: true),
        Case(transport: builtIn, dataSource: headphones, speakers: false),
        Case(transport: kAudioDeviceTransportTypeUSB, dataSource: internalSpeakers, speakers: false),
        Case(transport: kAudioDeviceTransportTypeUSB, dataSource: nil, speakers: false),
        Case(transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil, speakers: false),
        Case(transport: builtIn, dataSource: nil, speakers: false),
        Case(transport: nil, dataSource: internalSpeakers, speakers: false),
    ]

    /// The flag that a refresh stores is the speaker value of the banner for the same reads.
    @Test(arguments: cases)
    func refreshFollowsTheBannerRule(_ item: Case) {
        let ring = ListenRing(rate: 48_000, inputBlock: 512, pull: 512)
        defer { ring.deallocate() }
        let read: (AudioObjectID) -> Bool = { _ in
            isBuiltInSpeakers(transport: item.transport, dataSource: item.dataSource)
        }
        SpeakerGuard.refresh(ring, output: { 7 }, watch: { _ in }, speakers: read)
        let banner = AudioDefaults.read(output: 7, inputUID: nil, watch: { _ in }, speakers: read).speakers
        #expect(ring.speakers == banner, "G7: the flag follows the banner rule")
        #expect(ring.speakers == item.speakers, "G7: the flag is the speaker value of the case")
    }

    /// No default output ID: the flag is true (the safe side), and the banner stays off.
    @Test func aFailedOutputReadSilences() {
        let ring = ListenRing(rate: 48_000, inputBlock: 512, pull: 512)
        defer { ring.deallocate() }
        refreshOn(ring, dataSource: headphones)
        #expect(!ring.speakers, "the headphones refresh stores false")
        refreshOn(ring, output: nil, dataSource: headphones)
        #expect(ring.speakers, "G7: a failed output read silences the monitor")
        let banner = AudioDefaults.read(output: nil, inputUID: nil, watch: { _ in }, speakers: { _ in true })
        #expect(!banner.speakers, "a failed output read shows no banner")
    }

    @Test func theWatchComesBeforeTheRead() {
        let ring = ListenRing(rate: 48_000, inputBlock: 512, pull: 512)
        defer { ring.deallocate() }
        var calls: [String] = []
        SpeakerGuard.refresh(
            ring,
            output: {
                calls.append("output")
                return 7
            }, watch: { calls.append("watch \($0)") },
            speakers: {
                calls.append("read \($0)")
                return false
            })
        #expect(calls == ["output", "watch 7", "read 7"], "G7: the watch comes before the read")
    }

    /// A refresh with output 7, then one with output 9: both get a watch, and the flag follows 9.
    /// The test holds the main actor and never awaits, so the refresh needs no main actor turn.
    @MainActor @Test func aNewDefaultOutputGetsAWatch() {
        let ring = ListenRing(rate: 48_000, inputBlock: 512, pull: 512)
        let hal = FakeListeners()
        defer {
            SpeakerGuard.close(ring, remove: hal.remove)
            ring.deallocate()
        }
        SpeakerGuard.refresh(ring, output: { 7 }, watch: hal.watch(ring), speakers: { _ in false })
        #expect(!ring.speakers, "G17: the first refresh stores its flag")
        SpeakerGuard.refresh(ring, output: { 9 }, watch: hal.watch(ring), speakers: { $0 == 9 })
        #expect(hal.listening == [7, 9], "G19: each default output gets a data source listener")
        #expect(ring.speakers, "G17: the flag follows the new default output")
    }

    /// A refresh inside the read of another refresh is newer: its value stays.
    @Test func aStaleRefreshDoesNotWin() {
        let ring = ListenRing(rate: 48_000, inputBlock: 512, pull: 512)
        defer { ring.deallocate() }
        SpeakerGuard.refresh(
            ring, output: { 7 }, watch: { _ in },
            speakers: { _ in
                refreshOn(ring, dataSource: headphones)
                return true
            })
        #expect(!ring.speakers, "G17: the older refresh does not overwrite the newer one")
    }

    /// Refresh A takes its ticket and waits in its output read. Refresh B on a second thread
    /// takes its ticket and waits. A reads the old value and stores, then B reads the new value.
    @Test func aLaterRefreshWinsOnAnotherThread() async {
        let ring = ListenRing(rate: 48_000, inputBlock: 512, pull: 512)
        defer { ring.deallocate() }
        let source = OSAllocatedUnfairLock(initialState: internalSpeakers)
        let gateA = Gate(limit: Gate.openLimit)
        let gateB = Gate(limit: Gate.openLimit)
        defer {
            gateA.open()
            gateB.open()
        }
        func refresh(_ gate: Gate) -> @Sendable () -> Void {
            {
                SpeakerGuard.refresh(
                    ring,
                    output: {
                        gate.waitOnce()
                        return 7
                    }, watch: { _ in },
                    speakers: { _ in isBuiltInSpeakers(transport: builtIn, dataSource: source.withLock { $0 }) })
            }
        }
        async let refreshA: Void = onThread(refresh(gateA))
        await gateA.entered()
        async let refreshB: Void = onThread(refresh(gateB))
        await gateB.entered()
        gateA.open()
        await refreshA
        #expect(ring.speakers, "refresh A stores the old value")
        source.withLock { $0 = headphones }
        gateB.open()
        await refreshB
        #expect(!ring.speakers, "G17: the later refresh wins")
    }

    /// An off that runs inside a refresh, in the output read or in the listener add, leaves no
    /// data source listener, and a later refresh adds none.
    @Test func aRefreshAcrossOffLeavesNoListener() {
        let first = ListenRing(rate: 48_000, inputBlock: 512, pull: 512)
        let firstHAL = FakeListeners()
        SpeakerGuard.refresh(
            first,
            output: {
                SpeakerGuard.close(first, remove: firstHAL.remove)
                return 7
            }, watch: firstHAL.watch(first), speakers: { _ in false })
        #expect(firstHAL.listening.isEmpty, "G19: an off in the output read leaves no listener")
        let second = ListenRing(rate: 48_000, inputBlock: 512, pull: 512)
        let secondHAL = FakeListeners { SpeakerGuard.close(second, remove: { _ in }) }
        SpeakerGuard.refresh(second, output: { 7 }, watch: secondHAL.watch(second), speakers: { _ in false })
        #expect(!second.speakers, "the refresh across the add stores its flag")
        #expect(secondHAL.listening.isEmpty, "G19: an off in the listener add leaves no listener")
        SpeakerGuard.refresh(second, output: { 9 }, watch: secondHAL.watch(second), speakers: { _ in false })
        #expect(secondHAL.listening.isEmpty, "G19: a refresh after the off adds no listener")
        first.deallocate()
        second.deallocate()
    }

    /// A11: a refresh from the headphones to the speakers silences the next buffer. Before it,
    /// a refresh that stays on the headphones keeps the sound.
    @Test func anUnplugSilencesAtTheNextBuffer() {
        let ring = ListenRing(rate: 48_000, inputBlock: 512, pull: 512)
        defer { ring.deallocate() }
        ring.setMap(ChannelMap(routes: [.mono(1)]))
        refreshOn(ring, dataSource: headphones)
        let signal = DeviceSignal.sines(seconds: 1, layout: [1])
        var played = play(DeviceSignal(channels: [Array(signal.channels[0][..<47_104])], layout: [1]), through: ring)
        let before = played.left.count
        withPaddedList(signal, 47_104..<47_616) { ring.push($0) }
        refreshOn(ring, dataSource: headphones)
        played.pull(ring, frames: 512)
        #expect(played.left[before...].contains { $0 != 0 }, "A11: the headphones keep the sound")
        withPaddedList(signal, 47_616..<48_000) { ring.push($0) }
        refreshOn(ring, dataSource: internalSpeakers)
        played.pull(ring, frames: 512)
        #expect(played.left[(before + 512)...].allSatisfy { $0 == 0 }, "A11: the speakers silence the next buffer")
    }
}
