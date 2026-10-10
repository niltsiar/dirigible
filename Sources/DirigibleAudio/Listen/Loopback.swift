import CoreAudio

/// The loopback devices of a listened input (decision 0044). An output that plays to one of them
/// feeds the monitor into its own input, so the speaker guard plays zeros.
enum Loopback: Sendable, Equatable {
    /// The input when its transport is virtual, and each virtual device under an aggregate input.
    /// Empty for a hardware input: a duplex USB interface with a headphone out is no loopback.
    case devices(Set<AudioObjectID>)
    /// A read failed: every output counts as a loopback (fail closed).
    case unknown

    /// True when one of `outputs` is a loopback device.
    func feeds(_ outputs: [AudioObjectID]) -> Bool {
        switch self {
        case .devices(let devices): outputs.contains(where: devices.contains)
        case .unknown: true
        }
    }
}

/// The loopback devices of `device`: the device when its transport is virtual. For an aggregate
/// or an auto-aggregate: the loopback devices of each active subdevice, and the aggregate when
/// there is one. A failed read, or an aggregate on its own `path`, gives `.unknown`. The active
/// list of an Apple aggregate holds no aggregate (probe P3 of run 1b), but a driver can report one.
func loopbackDevices(
    _ device: AudioObjectID, transport: (AudioObjectID) -> UInt32?, subdevices: (AudioObjectID) -> [AudioObjectID]?,
    path: Set<AudioObjectID> = []
) -> Loopback {
    switch transport(device) {
    case kAudioDeviceTransportTypeVirtual: return .devices([device])
    case nil: return .unknown
    case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate:
        guard !path.contains(device), let list = subdevices(device) else { return .unknown }
        var found: Set<AudioObjectID> = []
        for subdevice in list {
            let below = loopbackDevices(
                subdevice, transport: transport, subdevices: subdevices, path: path.union([device]))
            guard case .devices(let devices) = below else { return .unknown }
            found.formUnion(devices)
        }
        return .devices(found.isEmpty ? [] : found.union([device]))
    default: return .devices([])
    }
}
