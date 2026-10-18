import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A dispatch queue label reaches the crash and hang reports that the problem report copies
/// (decision 0059), so no label of a device queue holds the device UID.
@MainActor struct QueueLabelTests {
    static let uid = "FixtureUID-7F3A:input,2"
    let device = InputDevice(
        uid: uid, name: "Desk Mic", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [1],
        latency: 0)!

    /// The labels of the queues that call the HAL look-up.
    final class Labels: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        var all: [String] { lock.withLock { list } }
        func add(_ label: String) { lock.withLock { list.append(label) } }
    }

    func recording(_ hal: TestHAL, into labels: Labels) -> DeviceHAL {
        var recorded = hal.hal
        let lookUp = recorded.lookUp
        recorded.lookUp = { uid in
            labels.add(String(cString: __dispatch_queue_get_label(nil)))
            return lookUp(uid)
        }
        return recorded
    }

    @Test func aDeviceWriterQueueLabelHasNoUID() async throws {
        let folder = try TemporaryFolder()
        let labels = Labels()
        let url = folder.url
        let writer = DeviceWriter(
            device: device, tracks: [(arm: 1, channels: .mono(1))], files: TakeFiles(take: 1, folder: { url }),
            hal: recording(TestHAL([device]), into: labels), drainInterval: .seconds(3600))

        writer.start()
        await writer.started()
        await writer.finish()

        let all = labels.all
        try #require(!all.isEmpty, "the writer queue calls the look-up")
        #expect(all.allSatisfy { $0.hasPrefix("Dirigible.DeviceWriter") && !$0.contains(Self.uid) }, "\(all)")
    }

    @Test func aListenerQueueLabelHasNoUID() async throws {
        let labels = Labels()
        let listener = Listener(
            uid: Self.uid, map: ChannelMap(routes: [.mono(1)]), hal: recording(TestHAL([device]), into: labels),
            output: TestOutput().output, report: { _ in })

        listener.start()
        await until(limit: .seconds(10), "the Listener queue calls the look-up") { !labels.all.isEmpty }
        await listener.off()

        let all = labels.all
        #expect(all.allSatisfy { $0.hasPrefix("Dirigible.Listener") && !$0.contains(Self.uid) }, "\(all)")
    }
}
