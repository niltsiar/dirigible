import Atomics
import CoreAudio
import Foundation
import Observation
import os

/// The input devices and the default devices of the system (decision 0015). The first read of
/// `shared` installs the C listeners of `DeviceListListener`, off the main actor, and keeps them
/// for the process life. Each listener call, and each `changed()`, reads `InputDevice.all()` and
/// the defaults off the main actor: one read at a time, and one more when a call came during a read.
@Observable @MainActor public final class DeviceList {
    public static let shared = DeviceList(
        read: { InputDevice.all() }, defaults: { AudioDefaults.live() }, listens: true)

    public private(set) var devices: [InputDevice] = []
    public private(set) var defaults = AudioDefaults()
    /// The reads that ended. For tests.
    @ObservationIgnored private(set) var reads = 0
    @ObservationIgnored private let read: @Sendable () async -> [InputDevice]
    @ObservationIgnored private let readDefaults: @Sendable () -> AudioDefaults
    @ObservationIgnored private let listens: Bool
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var again = false

    /// Tests give the reads; the instance installs no listener. It reads once at once. The read is
    /// async, so a test holds it with an async wait and blocks no thread of the concurrency pool.
    convenience init(
        read: @escaping @Sendable () async -> [InputDevice],
        defaults: @escaping @Sendable () -> AudioDefaults = { AudioDefaults() }
    ) { self.init(read: read, defaults: defaults, listens: false) }

    private init(
        read: @escaping @Sendable () async -> [InputDevice], defaults: @escaping @Sendable () -> AudioDefaults,
        listens: Bool
    ) {
        self.read = read
        self.readDefaults = defaults
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
        let (read, readDefaults, listens) = (read, readDefaults, listens)
        Task {
            let (list, newDefaults) = await Self.load(read, readDefaults, listens: listens)
            reads += 1
            if list != devices { devices = list }
            if newDefaults != defaults { defaults = newDefaults }
            reading = false
            if again {
                again = false
                changed()
            }
        }
    }

    @concurrent private nonisolated static func load(
        _ read: @Sendable () async -> [InputDevice], _ readDefaults: @Sendable () -> AudioDefaults, listens: Bool
    ) async -> ([InputDevice], AudioDefaults) {
        if listens { _ = DeviceListListener.installed }
        return (await read(), readDefaults())
    }
}

/// The default input device and the speaker flag of the default output device.
public struct AudioDefaults: Equatable, Sendable {
    /// The UID of the default input device, or nil when there is none.
    public var inputUID: String?
    /// True when the default output device is the built-in speakers (`isBuiltInSpeakers`).
    public var speakers: Bool

    public init(inputUID: String? = nil, speakers: Bool = false) {
        self.inputUID = inputUID
        self.speakers = speakers
    }

    /// The read of the system, with the data source listener on the default output.
    static func live() -> AudioDefaults {
        read(
            output: liveDefault(kAudioHardwarePropertyDefaultOutputDevice),
            inputUID: liveDefault(kAudioHardwarePropertyDefaultInputDevice).flatMap {
                readString($0, kAudioDevicePropertyDeviceUID)
            },
            watch: DeviceListListener.watchDataSource, speakers: liveSpeakers)
    }

    /// The default device of `selector`, or nil when the read fails or there is none.
    static func liveDefault(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        let id = try? readValue(AudioObjectID(kAudioObjectSystemObject), selector, as: AudioObjectID.self)
        return id == AudioObjectID(kAudioObjectUnknown) ? nil : id
    }

    /// The live speaker read of `output`. The banner and the speaker flag of a listen ring use it.
    static func liveSpeakers(_ output: AudioObjectID) -> Bool {
        isBuiltInSpeakers(
            transport: try? readValue(output, kAudioDevicePropertyTransportType, as: UInt32.self),
            dataSource: try? readValue(
                output, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, as: UInt32.self))
    }

    /// Calls `watch` on the output device before it reads the flag, so a change after the read
    /// always calls the listener.
    static func read(
        output: AudioObjectID?, inputUID: String?, watch: (AudioObjectID) -> Void, speakers: (AudioObjectID) -> Bool
    ) -> AudioDefaults {
        guard let output else { return AudioDefaults(inputUID: inputUID) }
        watch(output)
        return AudioDefaults(inputUID: inputUID, speakers: speakers(output))
    }
}

/// True only for the built-in transport with the internal speaker data source ('ispk'). A
/// headphone plug changes the data source of the same device to 'hdpn' (probe P6). A built-in
/// device with no data source gives false: no false alarm (analysis U4).
func isBuiltInSpeakers(transport: UInt32?, dataSource: UInt32?) -> Bool {
    transport == kAudioDeviceTransportTypeBuiltIn && dataSource == 0x6973_706B  // 'ispk'
}

/// The process listeners, with no client data. They are never removed, so no call can reach
/// freed memory (probe Q3): `systemProperties` on the system object, and the output data source
/// of each default output device that a read finds.
enum DeviceListListener {
    static let offMain = 1
    static let onMain = 2
    /// 0 before the install; else `offMain` or `onMain`, the thread of the install. For tests.
    static let install = ManagedAtomic<Int>(0)
    /// The listener calls. For tests.
    static let calls = ManagedAtomic<Int>(0)

    static let systemProperties = [
        propertyAddress(kAudioHardwarePropertyDevices),
        propertyAddress(kAudioHardwarePropertyDefaultInputDevice),
        propertyAddress(kAudioHardwarePropertyDefaultOutputDevice),
    ]

    /// True when each add returned noErr. Swift runs a `static let` once, also for two first
    /// reads at once.
    static let installed: Bool = {
        install.store(Thread.isMainThread ? onMain : offMain, ordering: .relaxed)
        return systemProperties.map { property in
            var address = property
            return AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, proc, nil)
                == noErr
        }.allSatisfy { $0 }
    }()

    /// The output devices with a data source listener.
    private static let watched = OSAllocatedUnfairLock(initialState: Set<AudioObjectID>())

    /// Adds the data source listener to `device` once. A failed add lets the next read try again.
    static func watchDataSource(_ device: AudioObjectID) {
        guard watched.withLock({ $0.insert(device).inserted }) else { return }
        var address = propertyAddress(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
        if AudioObjectAddPropertyListener(device, &address, proc, nil) != noErr {
            _ = watched.withLock { $0.remove(device) }
        }
    }

    private static let proc: AudioObjectPropertyListenerProc = { _, _, _, _ in
        DeviceListListener.calls.wrappingIncrement(ordering: .relaxed)
        Task { @MainActor in DeviceList.shared.changed() }
        return noErr
    }
}
