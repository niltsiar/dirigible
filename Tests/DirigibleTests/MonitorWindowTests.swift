import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// The window side of the input monitor (decision 0015): the device list, the route state, and
/// the Monitor Inputs toggle with real windows and real packages.
@MainActor struct MonitorWindowTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()
    let duo = InputDevice(
        uid: "duo", name: "Duo", nominalRate: 48_000, availableRates: [48_000...48_000], channelsPerBuffer: [2],
        latency: 0)!

    init() throws { folder = try TemporaryFolder() }

    /// A package with `t1` on channel 1 of `duo` and `t2` on channel 2. The write runs off the
    /// main actor (the tdd skill).
    func package() async throws -> URL {
        let package = folder.url.appending(path: "monitor.dirigible")
        try await Task.detached {
            var session = Session(sampleRate: 48_000)
            try session.addTrack("t1", name: "Host", layout: .mono)
            try session.addTrack("t2", name: "Guest", layout: .mono)
            try session.setRoute(Route(deviceUID: "duo", channels: .mono(1)), track: "t1")
            try session.setRoute(Route(deviceUID: "duo", channels: .mono(2)), track: "t2")
            try session.write(to: package)
        }.value
        return package
    }

    /// A window on the package, with the counting HAL.
    func window() async throws -> (SessionWindow, Studio) {
        let window = await app.open(try await package())
        let studio = try #require(await window.opened() ? window.studio : nil)
        studio.environment = hal.environment
        return (window, studio)
    }

    // MARK: Criterion 13

    @Test func aDeviceChangeUpdatesTheDeviceList() async throws {
        let present = OSAllocatedUnfairLock(initialState: [InputDevice]())
        let list = DeviceList { present.withLock { $0 } }
        let window = SessionWindow(url: folder.url, recordings: nil, app: app)
        window.deviceList = list
        await until("no first read") { list.reads == 1 }
        #expect(window.devices.isEmpty)

        present.withLock { $0 = [duo] }
        list.changed()
        await until("the window did not get the new list") { window.devices == [duo] }
    }

    /// The control: with no `changed()`, the window keeps the old list, also past 2 s.
    @Test func noChangeKeepsTheDeviceList() async throws {
        let present = OSAllocatedUnfairLock(initialState: [InputDevice]())
        let list = DeviceList { present.withLock { $0 } }
        let window = SessionWindow(url: folder.url, recordings: nil, app: app)
        window.deviceList = list
        await until("no first read") { list.reads == 1 }

        present.withLock { $0 = [duo] }
        try await Task.sleep(for: .milliseconds(2500))
        #expect(window.devices.isEmpty)
    }

    // MARK: Criterion 14

    /// Control in the same test: with the device in the list, the label is its name.
    @Test func aMissingRouteDeviceShowsMissing() {
        let route = Route(deviceUID: "duo", channels: .mono(1))
        #expect(routeLabel(route: route, devices: []) == L10n.trackRouteMissing.text)
        #expect(routeLabel(route: route, devices: [duo]) == "Duo")
    }

    // MARK: Criterion 15

    @Test func theToggleAndTheArmSetDriveTheMonitor() async throws {
        let (window, studio) = try await window()
        #expect(window.armed == ["t1", "t2"])

        window.monitoring = true
        await until("the toggle did not start the monitor") {
            studio.liveTracks["t1"]?.state == .monitoring && studio.liveTracks["t2"]?.state == .monitoring
                && hal.attaches == 1
        }

        window.armed = []
        await until("disarm did not free the device") { studio.liveTracks.isEmpty && hal.isFree }

        window.armed = ["t1"]
        await until("arm did not start the monitor") { hal.attaches == 2 && studio.liveTracks["t1"] != nil }
        await window.close()
        #expect(hal.isFree)
    }

    /// Code gate round 1, item 3: the toggle goes on while the window opens. The open starts the
    /// monitor. Control: criterion 15, the toggle after the open.
    @Test func aToggleDuringTheOpenStartsTheMonitor() async throws {
        let studio = try await Studio.open(try await package())
        studio.environment = hal.environment
        let window = SessionWindow(url: studio.url, recordings: nil, app: app)
        window.monitoring = true

        window.adopt(studio)
        await until("the open did not start the monitor") {
            hal.attaches == 1 && studio.liveTracks["t2"]?.state == .monitoring
        }
        await window.close()
        #expect(hal.isFree)
    }

    /// Code gate round 1, item 3 sibling: the toggle goes on while a close waits for "Close
    /// anyway?". Cancel opens the window again and starts the monitor.
    @Test func aToggleDuringACancelledCloseStartsTheMonitor() async throws {
        let (window, studio) = try await window()
        studio.environment.saveSession = { _, _ throws(SessionFileError) in
            throw .writeFailed(step: "test", errno: EIO)
        }
        try studio.edit { s throws(SessionError) in try s.renameTrack("t1", to: "Hostess") }
        await window.close()
        #expect(window.alert == .confirmUnsavedClose)

        window.monitoring = true
        // The follow of the toggle runs now, in the closing phase.
        await Task.yield()
        #expect(hal.attaches == 0)
        window.cancelUnsavedClose()
        await until("the cancel did not start the monitor") { hal.attaches == 1 }

        await window.close()
        window.closeAnyway()
        #expect(hal.isFree)
    }

    /// Code gate round 2, item 2: the toggle is enabled only in the open phase, like the other
    /// Record items. Control in the same test: the open phase enables it.
    @Test func theToggleIsEnabledOnlyWhenTheWindowIsOpen() async throws {
        let (window, studio) = try await window()
        #expect(window.canMonitor)
        studio.environment.saveSession = { _, _ throws(SessionFileError) in
            throw .writeFailed(step: "test", errno: EIO)
        }
        try studio.edit { s throws(SessionError) in try s.renameTrack("t1", to: "Hostess") }
        await window.close()
        #expect(window.alert == .confirmUnsavedClose)
        #expect(!window.canMonitor)
        window.closeAnyway()

        let failed = SessionWindow(url: folder.url.appending(path: "none.dirigible"), recordings: nil, app: app)
        failed.open(recovering: false)
        await until("the open did not fail") {
            if case .failed = failed.phase { true } else { false }
        }
        #expect(!failed.canMonitor)
    }

    // MARK: Criterion 23

    /// Control: with the toggle on, `updateMonitor()` attaches.
    @Test func aSettleTurnsTheToggleOff() async throws {
        let (window, studio) = try await window()
        window.monitoring = true
        await window.updateMonitor()
        await until("no monitor attach") { hal.attaches == 1 }

        await window.settle()
        #expect(!window.monitoring)
        #expect(hal.isFree)
        await window.updateMonitor()
        try await Task.sleep(for: .milliseconds(200))
        #expect(hal.attaches == 1)
        #expect(studio.liveTracks.isEmpty)
        await window.close()
    }
}
