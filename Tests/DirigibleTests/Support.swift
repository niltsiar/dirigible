import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// Polls `condition` every 10 ms. At the limit, it records `message` as an issue and returns.
/// The default limit is 60 s, longer than the whole suite: in a full run, the DirigibleAudio
/// tests hold the main actor (`PendingTakeTests.init` and `Studio.startTake` write with
/// `F_FULLFSYNC`) and the cooperative threads (blocking file writes) for most of the run, and a
/// window open needs both.
@MainActor func until(limit: Duration = .seconds(60), _ message: String, _ condition: () -> Bool) async {
    let end = ContinuousClock.now + limit
    while !condition() {
        guard ContinuousClock.now < end else {
            Issue.record("\(message) (limit \(limit))")
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

/// A unique temporary folder under `parent`, removed after deinit.
final class TemporaryFolder {
    let url: URL

    init(in parent: URL = FileManager.default.temporaryDirectory) throws {
        url = parent.appending(path: "DirigibleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// The removal runs off the calling thread. Most suites are `@MainActor`, and under the disk
    /// load of `make test-slow` one removal takes 100 ms or more on the main actor (the tdd skill).
    /// Limit: a removal that has not run when the process exits leaves its folder.
    deinit {
        let url = url
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: url) }
    }

    /// A new session package in the folder.
    func package(_ name: String) throws -> URL {
        let url = url.appending(path: "\(name).dirigible")
        try Session.create(at: url, sampleRate: 48_000)
        return url
    }
}

extension SessionWindow {
    /// Waits until the open of the package ends with a studio.
    func opened() async -> Bool {
        await until("the window opens its package") { studio != nil }
        if studio == nil { Issue.record("The phase is \(phase)") }
        return studio != nil
    }
}

/// A closure `DeviceHAL` with one device `duo` (2 channels, 48 kHz, object 7). It counts the
/// attaches and the clean detaches; "the device is free" is `attaches == cleanDetaches`. The app
/// test target cannot import `TestHAL` of `DirigibleAudioTests`.
final class CountingHAL: Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: (attaches: 0, cleanDetaches: 0))

    var attaches: Int { counts.withLock { $0.attaches } }
    var isFree: Bool { counts.withLock { $0.attaches == $0.cleanDetaches } }

    /// The live environment with this HAL, the access granted, and a watchdog limit of 60 s, so
    /// a device with no records is never lost in a test.
    var environment: CaptureEnvironment {
        let duo = InputDevice(
            uid: "duo", name: "Duo", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [2],
            latency: 0)!
        var environment = CaptureEnvironment.live
        environment.hal = DeviceHAL(
            lookUp: { $0 == duo.uid ? (7, duo) : nil },
            attach: { [counts] _ in
                counts.withLock { $0.attaches += 1 }
                return {
                    counts.withLock { $0.cleanDetaches += 1 }
                    return true
                }
            }, watchDevices: { _ in { true } })
        environment.microphoneAccess = { nil }
        environment.silenceLimit = .seconds(60)
        environment.firstRecordLimit = .seconds(60)
        return environment
    }
}
