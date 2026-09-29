import Atomics
import CoreAudio
import Foundation
import Observation

/// The input devices of the system (decision 0015). The first read of `shared` installs one C
/// listener on the device list, off the main actor, and keeps it for the process life. Each
/// listener call, and each `changed()`, reads `InputDevice.all()` off the main actor: one read
/// at a time, and one more when a call came during a read.
@Observable @MainActor public final class DeviceList {
    public static let shared = DeviceList(read: { InputDevice.all() }, listens: true)

    public private(set) var devices: [InputDevice] = []
    /// The reads that ended. For tests.
    @ObservationIgnored private(set) var reads = 0
    @ObservationIgnored private let read: @Sendable () async -> [InputDevice]
    @ObservationIgnored private let listens: Bool
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var again = false

    /// Tests give the read; the instance installs no listener. It reads once at once. The read is
    /// async, so a test holds it with an async wait and blocks no thread of the concurrency pool.
    convenience init(read: @escaping @Sendable () async -> [InputDevice]) { self.init(read: read, listens: false) }

    private init(read: @escaping @Sendable () async -> [InputDevice], listens: Bool) {
        self.read = read
        self.listens = listens
        changed()
    }

    /// Reads the list again (the listener calls it; the window calls it when it becomes key).
    public func changed() {
        guard !reading else {
            again = true
            return
        }
        reading = true
        let (read, listens) = (read, listens)
        Task {
            let list = await Self.load(read, listens: listens)
            reads += 1
            if list != devices { devices = list }
            reading = false
            if again {
                again = false
                changed()
            }
        }
    }

    @concurrent private nonisolated static func load(_ read: @Sendable () async -> [InputDevice], listens: Bool) async
        -> [InputDevice]
    {
        if listens { _ = DeviceListListener.installed }
        return await read()
    }
}

/// The process listener on `kAudioHardwarePropertyDevices` of the system object, with no client
/// data. It is never removed, so no call can reach freed memory (probe Q3).
enum DeviceListListener {
    static let offMain = 1
    static let onMain = 2
    /// 0 before the install; else `offMain` or `onMain`, the thread of the install. For tests.
    static let install = ManagedAtomic<Int>(0)
    /// The listener calls. For tests.
    static let calls = ManagedAtomic<Int>(0)

    /// True when the add returned noErr. Swift runs a `static let` once, also for two first
    /// reads at once.
    static let installed: Bool = {
        install.store(Thread.isMainThread ? onMain : offMain, ordering: .relaxed)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, proc, nil) == noErr
    }()

    private static let proc: AudioObjectPropertyListenerProc = { _, _, _, _ in
        DeviceListListener.calls.wrappingIncrement(ordering: .relaxed)
        Task { @MainActor in DeviceList.shared.changed() }
        return noErr
    }
}
