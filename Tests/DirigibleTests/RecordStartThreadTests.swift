import CoreAudio
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// A start call of a take that the test environment fakes: the HAL calls of a device and of an
/// app source (decision 0030), the microphone status read, and the free space read.
enum StartCall: String, CaseIterable, Sendable {
    case lookUp, microphoneAccess, freeBytes, watchDevices, attach, lookUpApp, appName, makeTap
}

/// Records the thread of each start call. After `arm()`, the first call of `held` waits until
/// `release()` or `limit`, as a HAL call that waits for coreaudiod or for a prompt.
final class StartHold: Sendable {
    /// A main-actor hop under a loaded suite can take seconds, so the limit is wide. A release
    /// ends the hold before it.
    static let limit = Duration.seconds(20)
    let held: StartCall
    private let state = OSAllocatedUnfairLock(
        initialState: (
            armed: false, entered: false, released: false, timedOut: false, calls: Set<StartCall>(),
            mainCalls: Set<StartCall>()
        ))

    init(_ held: StartCall) { self.held = held }

    var calls: Set<StartCall> { state.withLock { $0.calls } }
    var mainCalls: Set<StartCall> { state.withLock { $0.mainCalls } }
    var timedOut: Bool { state.withLock { $0.timedOut } }

    func arm() { state.withLock { $0.armed = true } }
    func release() { state.withLock { $0.released = true } }

    func call(_ call: StartCall) {
        let holds = state.withLock { state -> Bool in
            state.calls.insert(call)
            if Thread.isMainThread { state.mainCalls.insert(call) }
            guard call == held, state.armed, !state.entered else { return false }
            state.entered = true
            return true
        }
        guard holds else { return }
        let end = ContinuousClock.now + Self.limit
        while !state.withLock({ $0.released }) {
            guard ContinuousClock.now < end else { return state.withLock { $0.timedOut = true } }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// True when the held call waits now; false after 60 s.
    func entered() async -> Bool {
        let end = ContinuousClock.now + .seconds(60)
        while !state.withLock({ $0.entered }) {
            guard ContinuousClock.now < end else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

/// The bundle ID of the call app of the app track.
private let zoomBundleID = "us.zoom.xos"

/// Suspect R1 of the record-start hang: a start call that can block runs on the main thread, or
/// the main thread waits for it. Each case holds one start call and checks that the main actor
/// runs a job and the window shows the start meanwhile.
@Suite(.serialized) @MainActor struct RecordStartThreadTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let counting = CountingHAL()

    init() throws { folder = try TemporaryFolder() }

    /// Track t1 on channel 1 of `duo`, and track t2 on the app source of Zoom. The write runs off
    /// the main actor.
    func package() async throws -> URL {
        let url = folder.url.appending(path: "start.dirigible")
        try await Task.detached {
            var session = Session(sampleRate: 48_000)
            try session.addTrack(TrackID("t1"), name: "Mic", layout: .mono)
            try session.setRoute(Route.device(uid: "duo", channels: .mono(1)), track: TrackID("t1"))
            try session.addTrack(TrackID("t2"), name: "Call", layout: .stereo)
            try session.setRoute(Route.app(bundleID: zoomBundleID), track: TrackID("t2"))
            try session.write(to: url)
        }.value
        return url
    }

    /// The counting HAL with an app source of Zoom, each start call through `hold`. The take
    /// start arms the hold off the main actor, before its first HAL call.
    func environment(_ hold: StartHold) -> CaptureEnvironment {
        var environment = counting.environment
        let hal = environment.hal
        let app = InputDevice(
            uid: appUID(zoomBundleID), name: "zoom.us", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelsPerBuffer: [2], latency: 0)!
        let found = AppFound(
            key: AppKey(processes: [41], output: nil), output: "BuiltInSpeakerDevice", device: app, playing: true)
        let tap = InputDevice(
            uid: "com.delineas.dirigible.tap.1001", name: "Tap", nominalRate: 48_000,
            availableRates: [48_000...48_000], channelsPerBuffer: [2], latency: 0)!
        environment.beforeLookUp = { hold.arm() }
        environment.hal.lookUp = { uid in
            hold.call(.lookUp)
            return hal.lookUp(uid)
        }
        environment.hal.attach = { input throws(HALError) in
            hold.call(.attach)
            return try hal.attach(input)
        }
        environment.hal.watchDevices = { writer in
            hold.call(.watchDevices)
            return hal.watchDevices(writer)
        }
        environment.hal.lookUpApp = { bundleID, _ in
            hold.call(.lookUpApp)
            return bundleID == zoomBundleID ? found : nil
        }
        environment.hal.appName = { _ in
            hold.call(.appName)
            return "zoom.us"
        }
        environment.hal.makeTap = { _ throws(HALError) in
            hold.call(.makeTap)
            return (1001, tap, { true })
        }
        environment.microphoneAccess = {
            hold.call(.microphoneAccess)
            return nil
        }
        environment.freeBytes = { _ in
            hold.call(.freeBytes)
            return 100_000_000_000
        }
        return environment
    }

    /// Command-R with one start call held: the main actor runs a job while the call waits, the
    /// Record command is off, and a close asks first. After the release, the take records on
    /// both tracks. No start call runs on the main thread. Each case also proves that every
    /// start call ran.
    @Test(arguments: StartCall.allCases) func heldStartCallLeavesTheMainActorFree(_ held: StartCall) async throws {
        let model = await app.open(try await package())
        let studio = try #require(await model.opened() ? model.studio : nil)
        let hold = StartHold(held)
        studio.environment = environment(hold)
        #expect(model.armedWithRoute == [TrackID("t1"), TrackID("t2")], "the window did not arm both tracks")

        let start = Task { await model.record() }
        // Off the main actor: when the held call blocks the main thread, this task still runs.
        let seen = await Task.detached { () -> (canRecord: Bool, running: Bool, wait: Duration)? in
            guard await hold.entered() else { return nil }
            let before = ContinuousClock.now
            let window = await MainActor.run { (model.canRecord, model.isTakeRunning) }
            let wait = ContinuousClock.now - before
            hold.release()
            return (window.0, window.1, wait)
        }.value
        await start.value

        let reached = try #require(seen, "the start never called \(held)")
        print("R1 heartbeat \(held.rawValue): main-actor job ran \(reached.wait) after the hold")
        #expect(!hold.timedOut, "no main-actor job ran while \(held) was held: the main thread waits for it")
        #expect(!reached.canRecord && reached.running, "the window showed no start while \(held) was held")
        #expect(studio.transport == .recording(take: 1))
        await until("both writers attach") { counting.attaches == 2 }
        #expect(hold.mainCalls.isEmpty, "start calls on the main thread: \(hold.mainCalls.map(\.rawValue).sorted())")
        let missing = Set(StartCall.allCases).subtracting(hold.calls)
        #expect(missing.isEmpty, "start calls that never ran: \(missing.map(\.rawValue).sorted())")

        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        await model.close()
    }
}
