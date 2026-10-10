import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The loopback rule of the Listener (decision 0044): a monitor that can feed its own input plays
/// zeros, and a change of the subdevices of an aggregate input reads the set again.
extension ListenerTests {
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

    /// An unknown loopback set plays zeros and reports quiet, so the header shows the text that
    /// asks for a toggle, which reads the set again. A known loopback device keeps `.loopback`
    /// (code gate round 2, item 4). The aggregate lists itself (the mic has ID 1), so its set
    /// is unknown.
    @Test func anUnknownLoopbackIsQuiet() async throws {
        hal.setAggregate("mic", subdevices: [1], virtual: [])
        output.setOutput(5)
        let listener = listener()
        listener.start()
        let input = try #require(await input(after: [.quiet]), "an unknown set reports quiet")
        #expect(input.ring.speakers, "an unknown set plays zeros")
        await listener.off()
    }

    /// A subdevice event with the same loopback set keeps the appearance and its sound (code
    /// gate round 2, item 5). Probe P11: an IO start or stop on an aggregate sends no event.
    @Test func aSubdeviceEventWithTheSameSetKeepsPlaying() async throws {
        hal.setAggregate("mic", subdevices: [40, 41], virtual: [41])
        output.setOutput(40)
        let listener = listener()
        listener.start()
        let first = try #require(await input(after: [.playing]))
        listener.post(.subdevices, from: first)
        #expect(await listener.counts().kept == 0, "no restart")
        #expect(hal.listenTries("mic").count == 1 && !first.ring.speakers, "the appearance plays")
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
}
