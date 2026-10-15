import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// The window side of the input monitor (decision 0015): the device list, the route state, and
/// the Input Levels toggle with real windows and real packages.
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
            try session.setRoute(Route.device(uid: "duo", channels: .mono(1)), track: "t1")
            try session.setRoute(Route.device(uid: "duo", channels: .mono(2)), track: "t2")
            try session.write(to: package)
        }.value
        return package
    }

    /// A window on the package, with the counting HAL.
    func window() async throws -> (SessionWindow, Studio) {
        let window = await app.open(try await package())
        let studio = try #require(await window.opened() ? window.studio : nil)
        try await fixFreeSpace(window)
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
        #expect(routeLabel(uid: "duo", devices: []) == L10n.trackRouteMissing.text)
        #expect(routeLabel(uid: "duo", devices: [duo]) == "Duo")
    }

    /// Two mics of one model have one name: the second and later ones in UID order get the lowest
    /// free " 2", " 3", in the input menu and in the route label. A replug that changes the order of
    /// the device list keeps each name.
    @Test func aRepeatedDeviceNameGetsANumber() throws {
        func device(_ uid: String, _ name: String) throws -> InputDevice {
            try #require(
                InputDevice(
                    uid: uid, name: name, nominalRate: 48_000, availableRates: [48_000...48_000],
                    channelsPerBuffer: [1], latency: 0))
        }
        let (a, b, c) = (try device("a", "USB Mic"), try device("b", "USB Mic"), try device("c", "USB Mic"))
        let other = try device("o", "Duo")

        #expect(deviceNames([a, other, b]) == ["USB Mic", "Duo", "USB Mic 2"], "two equal names")
        #expect(deviceNames([a, b, other, c]) == ["USB Mic", "USB Mic 2", "Duo", "USB Mic 3"], "three equal names")
        #expect(deviceNames([other, a]) == ["Duo", "USB Mic"], "no repeat")
        #expect(routeLabel(uid: "b", devices: [a, other, b]) == "USB Mic 2")
        #expect(routeLabel(uid: "a", devices: [a, other, b]) == "USB Mic")
        #expect(deviceNames([b, other, a]) == ["USB Mic 2", "Duo", "USB Mic"], "a replug changes the list order")
        #expect(routeLabel(uid: "b", devices: [b, other, a]) == "USB Mic 2")
        let named = try device("d", "USB Mic 2")
        #expect(deviceNames([a, b, named]) == ["USB Mic", "USB Mic 3", "USB Mic 2"], "a device has the number")
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
        try studio.edit(ripple: false) { s throws(SessionError) in try s.renameTrack("t1", to: "Hostess") }
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
        try studio.edit(ripple: false) { s throws(SessionError) in try s.renameTrack("t1", to: "Hostess") }
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
