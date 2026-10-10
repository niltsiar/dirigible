import CoreAudio
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// The device list of decision 0015: one process listener and coalesced reads. Serialized: the
/// tests that make a private aggregate device wake the listener, so no other test of the suite
/// runs at that time. A test of another suite can still wake it: an engine start fires a
/// device-list call (probe P2 of run 2026-10-10-record-monitor-button).
@MainActor
@Suite(.serialized)
struct DeviceListListenerTests {
    /// A private aggregate device with no sub-device: this process sees it, and it needs no
    /// microphone and no prompt (probe Q3). Returns its object, or nil.
    nonisolated static func makeAggregate() -> AudioObjectID? {
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "dirigible.test.aggregate.\(getpid())",
            kAudioAggregateDeviceNameKey: "Dirigible test", kAudioAggregateDeviceIsPrivateKey: 1,
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        return AudioHardwareCreateAggregateDevice(description as CFDictionary, &id) == noErr ? id : nil
    }

    // MARK: Criterion 12

    /// Control in the same test: with no change, the call count stays the same for 0.5 s. A
    /// test of another suite can change the devices, so the control waits for one window of
    /// 0.5 s with no call; a listener that calls with no change never gives one.
    @Test func aPrivateAggregateDeviceWakesTheListener() async throws {
        let list = DeviceList.shared
        await until(limit: .seconds(20), "no first read of the shared list") { list.reads >= 1 }
        #expect(DeviceListListener.install.load(ordering: .relaxed) == DeviceListListener.offMain)

        var quiet = false
        for _ in 0..<40 where !quiet {
            let before = DeviceListListener.calls.load(ordering: .relaxed)
            try await Task.sleep(for: .milliseconds(500))
            quiet = DeviceListListener.calls.load(ordering: .relaxed) == before
        }
        #expect(quiet, "no window of 0.5 s with no device-list call in 20 s")

        let (calls, reads) = (DeviceListListener.calls.load(ordering: .relaxed), list.reads)
        let made = LockedBox<AudioObjectID>()
        try await offMainActor { made.value = Self.makeAggregate() }
        let id = try #require(made.value)
        await until(limit: .seconds(5), "no listener call for the make") {
            DeviceListListener.calls.load(ordering: .relaxed) > calls && list.reads > reads
        }

        let (callsAfterMake, readsAfterMake) = (DeviceListListener.calls.load(ordering: .relaxed), list.reads)
        try await offMainActor { #expect(AudioHardwareDestroyAggregateDevice(id) == noErr) }
        await until(limit: .seconds(5), "no listener call for the destroy") {
            DeviceListListener.calls.load(ordering: .relaxed) > callsAfterMake && list.reads > readsAfterMake
        }
    }

    // MARK: Criterion 13, part

    /// The first read waits on a gate while 5 more calls come: one more read runs after it, and
    /// its list wins.
    @Test func aBurstGivesAtMostTwoReads() async throws {
        let gate = AsyncGate()
        let count = StepCounter()
        let lists: [[InputDevice]] = [
            [],
            [
                InputDevice(
                    uid: "mic", name: "Mic", nominalRate: 48_000, availableRates: [], channelsPerBuffer: [1], latency: 0
                )!
            ],
        ]
        let list = DeviceList {
            _ = count.next()
            await gate.wait()
            return lists[min(count.calls, 2) - 1]
        }
        await gate.entered()
        for _ in 0..<5 { list.changed() }
        gate.open()

        await until(limit: .seconds(20), "the burst did not end") { list.reads == 2 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(count.calls == 2)
        #expect(list.devices.map(\.uid) == ["mic"])
    }

    // MARK: B2b

    /// The first of the two device listeners adds and the second fails: the watch removes both,
    /// so the next read adds each once again (code gate round 2, item 2). The device is fake.
    @Test func aPartialDataSourceAddIsRemoved() {
        var added: [AudioObjectPropertySelector] = []
        var removed: [AudioObjectPropertySelector] = []
        DeviceListListener.watchDataSource(
            0x7E57_0001,
            add: { _, property in
                added.append(property.mSelector)
                return added.count == 1
            },
            remove: { _, property in removed.append(property.mSelector) })
        #expect(added.count == 2 && removed == added, "a partial add removes the listener that it added")
    }

    /// The system listener watches the device list and both default devices. The read of the
    /// defaults installs the data source listener on the default output before it reads the
    /// flag, so no change falls between them. A seam: no assert reads the output of this Mac.
    @Test func theListenerWatchesTheDefaultDevices() {
        #expect(
            DeviceListListener.systemProperties.map(\.mSelector) == [
                kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice,
                kAudioHardwarePropertyDefaultOutputDevice,
            ], "the system listener misses a default device")
        var calls: [String] = []
        let defaults = AudioDefaults.read(
            output: 42, inputUID: "mic", watch: { calls.append("watch \($0)") },
            speakers: {
                calls.append("read \($0)")
                return true
            })
        #expect(calls.contains("watch 42"), "no data source listener on the default output")
        #expect(calls == ["watch 42", "read 42"], "the flag read comes before the data source install")
        #expect(defaults == AudioDefaults(inputUID: "mic", speakers: true))
    }

    // MARK: Pool health

    /// As many reads as the concurrency pool is wide wait at the async read seam, and a pool hop
    /// still ends at once: an async wait holds no pool thread. The test proves the hold after it:
    /// every holder entered before the hop, and no holder ended before the hop.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func anAsyncSeamHoldsNoPoolThread() async {
        let count = ProcessInfo.processInfo.activeProcessorCount
        let entered = StepCounter()
        let ended = StepCounter()
        let release = OSAllocatedUnfairLock(initialState: false)
        let start = ContinuousClock.now
        for _ in 0..<count {
            _ = DeviceList {
                _ = entered.next()
                while !release.withLock({ $0 }), ContinuousClock.now < start + .seconds(30) {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                _ = ended.next()
                return []
            }
        }
        await until(limit: .seconds(5), "a holder did not enter") { entered.calls == count }
        let hop = ContinuousClock.now
        await Task.detached {}.value
        let (elapsed, endedAtHop) = (ContinuousClock.now - hop, ended.calls)
        release.withLock { $0 = true }
        await until(limit: .seconds(20), "a hold did not end") { ended.calls == count }
        #expect(elapsed < .seconds(5), "the pool hop waited \(elapsed)")
        #expect(endedAtHop == 0, "a hold ended before the hop")
    }
}
