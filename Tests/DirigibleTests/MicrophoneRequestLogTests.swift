import AppKit
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// C39: the microphone request of the app writes its begin line to the log of the studio before
/// the macOS prompt, so a prompt that does not answer leaves the line in the file (decision 0059).
@MainActor struct MicrophoneRequestLogTests {
    let folder: TemporaryFolder
    let app: AppDelegate
    var logs: URL { folder.url.appending(path: "logs") }

    init() throws {
        folder = try TemporaryFolder()
        app = AppDelegate(recordings: nil, logFolder: folder.url.appending(path: "logs"))
    }

    /// The lines of each journal in `logs` after each queued line is written.
    static func lines(_ log: DiagnosticLog, in logs: URL) -> [String] {
        log.drain()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []).filter {
            $0.hasSuffix(".tsv")
        }
        return names.sorted().flatMap { name in
            String(decoding: (try? Data(contentsOf: logs.appending(path: name))) ?? Data(), as: UTF8.self)
                .split(separator: "\n").map(String.init)
        }
    }

    /// The prompt reads the file while it shows: the begin line is there, and the answer line is
    /// not. After the answer, the answer line is there.
    @Test func aHeldRequestLeavesItsBeginLine() async throws {
        app.applicationWillFinishLaunching(Notification(name: NSApplication.willFinishLaunchingNotification))
        let mic = try #require(
            InputDevice(
                uid: "mic", name: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
                channelsPerBuffer: [1], latency: 0))
        let package = folder.url.appending(path: "prompt.dirigible")
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRoute(Route.device(uid: mic.uid, channels: .mono(1)), track: "t1")
        try session.write(to: package)
        let window = await app.open(package)
        let studio = try #require(await window.opened() ? window.studio : nil)
        let log = studio.log
        #expect(log.isEnabled)
        let granted = OSAllocatedUnfairLock(initialState: false)
        var environment = CaptureEnvironment(
            hal: DeviceHAL(
                lookUp: { $0 == mic.uid ? (1, mic) : nil }, attach: { _ in { true } }, watchDevices: { _ in { true } },
                attachListen: { _ in (512, 48_000, { true }) }),
            silenceLimit: noWatchdog, firstRecordLimit: noWatchdog,
            microphoneAccess: { granted.withLock { $0 } ? nil : .notDetermined }, freeBytes: { _ in .max },
            diskCheckInterval: .seconds(60), saveSession: CaptureEnvironment.live.saveSession,
            listenOutput: .offline())
        environment.log = log
        studio.environment = environment
        let logs = logs
        var during: [String]?
        window.requestMicrophoneAccess = {
            during = Self.lines(log, in: logs)
            granted.withLock { $0 = true }
            return true
        }

        await window.record()

        let held = try #require(during, "no prompt")
        #expect(held.contains { $0.hasSuffix("\tpermission\tmicrophone-request-begin") }, "\(held)")
        #expect(!held.contains { $0.contains("\tpermission\tmicrophone-request\t") }, "\(held)")
        let after = Self.lines(log, in: logs)
        #expect(after.contains { $0.contains("\tpermission\tmicrophone-request\tgranted=yes\tms=") }, "\(after)")
        #expect(studio.transport == .recording(take: 1))
        try? await studio.stopRecording()
        await window.close()
    }
}
