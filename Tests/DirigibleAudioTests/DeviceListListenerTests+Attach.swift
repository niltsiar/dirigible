import CoreAudio
import Foundation
import Testing

@testable import DirigibleAudio

/// Pins of the live take attach and the live listen attach before they share one helper. An
/// empty private aggregate device opens no microphone and no speakers: the attach reaches the
/// IOProc, the listeners, and the start, which fails (probe P1 of run
/// 2026-10-10-record-monitor-button). The started path has no test here.
extension DeviceListListenerTests {
    nonisolated static let mic = InputDevice(
        uid: "mic", name: "Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    /// The live take attach on `id`: its error, and true when the input is freed after the call.
    nonisolated static func attachTake(_ id: AudioObjectID, writer: DeviceWriter) -> (HALError?, Bool) {
        let ring = CaptureRing(capacity: 1 << 16, rate: 48_000)
        defer { ring.deallocate() }
        weak var kept: DeviceInput?
        let error: HALError? = {
            let input = DeviceInput(id: id, ring: ring, writer: writer)
            kept = input
            do throws(HALError) {
                _ = try DeviceHAL.live.attach(input)()
                return nil
            } catch {
                return error
            }
        }()
        return (error, kept == nil)
    }

    /// The live listen attach on `id`: its error, and true when the input is freed after the call.
    nonisolated static func attachListen(_ id: AudioObjectID, listener: Listener) -> (HALError?, Bool) {
        let ring = ListenRing(rate: 48_000, inputBlock: 512, pull: 512)
        defer { ring.deallocate() }
        weak var kept: ListenInput?
        let error: HALError? = {
            let input = ListenInput(id: id, ring: ring, listener: listener)
            kept = input
            do throws(HALError) {
                _ = try DeviceHAL.live.attachListen(input).detach()
                return nil
            } catch {
                return error
            }
        }()
        return (error, kept == nil)
    }

    /// Makes an empty private aggregate, runs `body` on it off the main actor, and destroys it.
    /// Each make and destroy waits for its listener call, so no call of this test comes in the
    /// quiet window of another test of the suite.
    func withAggregate(_ body: @escaping @Sendable (AudioObjectID) throws -> Void) async throws {
        let list = DeviceList.shared
        await until(limit: .seconds(20), "no first read of the shared list") { list.reads >= 1 }
        let calls = DeviceListListener.calls.load(ordering: .relaxed)
        let made = LockedBox<AudioObjectID>()
        try await offMainActor { made.value = Self.makeAggregate() }
        let id = try #require(made.value)
        await until(limit: .seconds(5), "no listener call for the make") {
            DeviceListListener.calls.load(ordering: .relaxed) > calls
        }
        let callsAfterMake = DeviceListListener.calls.load(ordering: .relaxed)
        func destroy() async throws {
            try await offMainActor { #expect(AudioHardwareDestroyAggregateDevice(id) == noErr) }
            await until(limit: .seconds(5), "no listener call for the destroy") {
                DeviceListListener.calls.load(ordering: .relaxed) > callsAfterMake
            }
        }
        do {
            try await offMainActor { try body(id) }
        } catch {
            try await destroy()
            throw error
        }
        try await destroy()
    }

    /// The take attach undoes a failed start: the error is `.undone` with the start status, and
    /// every listener retain is released.
    @Test func theLiveAttachUndoesAFailedStart() async throws {
        let writer = DeviceWriter(
            device: Self.mic, tracks: [(arm: 1, channels: .mono(1))], files: nil, hal: TestHAL([]).hal)
        try await withAggregate { id in
            let (error, freed) = Self.attachTake(id, writer: writer)
            #expect(error == .undone(kAudioHardwareIllegalOperationError), "error: \(String(describing: error))")
            #expect(freed, "the input is freed after the attach")
        }
    }

    /// The listen attach undoes a failed start, as the take attach does.
    @Test func theListenAttachUndoesAFailedStart() async throws {
        let listener = Listener(
            uid: "mic", map: ChannelMap(routes: [.mono(1)]), hal: TestHAL([]).hal, output: .offline(), report: { _ in })
        try await withAggregate { id in
            let (error, freed) = Self.attachListen(id, listener: listener)
            #expect(error == .undone(kAudioHardwareIllegalOperationError), "error: \(String(describing: error))")
            #expect(freed, "the input is freed after the attach")
        }
    }

    /// On an object that does not exist, both attaches throw `.status` and keep nothing.
    @Test func aGoneObjectThrowsStatus() async throws {
        let writer = DeviceWriter(
            device: Self.mic, tracks: [(arm: 1, channels: .mono(1))], files: nil, hal: TestHAL([]).hal)
        let listener = Listener(
            uid: "mic", map: ChannelMap(routes: [.mono(1)]), hal: TestHAL([]).hal, output: .offline(), report: { _ in })
        try await offMainActor {
            let gone = AudioObjectID(0xDEAD)
            for (error, freed) in [Self.attachTake(gone, writer: writer), Self.attachListen(gone, listener: listener)] {
                guard case .status = error else {
                    Issue.record("not a status error: \(String(describing: error))")
                    continue
                }
                #expect(freed, "the input is freed after the attach")
            }
        }
    }
}
