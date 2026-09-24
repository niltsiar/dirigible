import CoreAudio

/// One appearance of a device, from a successful `attach` to its detach: the object ID and the
/// ring (decision 0013). A device that comes back gets a new `DeviceInput` with a new ring, so a
/// late IOProc call of an old appearance never reaches the ring of a new one. It holds the writer
/// weakly, so a kept input never keeps the writer alive. Set in `init` only.
final class DeviceInput: @unchecked Sendable {
    let id: AudioObjectID
    let ring: CaptureRing
    weak var writer: DeviceWriter?

    init(id: AudioObjectID, ring: CaptureRing, writer: DeviceWriter) {
        self.id = id
        self.ring = ring
        self.writer = writer
    }
}

/// The Core Audio calls of one device writer, as closures: the live value calls Core Audio, and
/// tests give closures. Not a protocol: two values, one type.
struct DeviceHAL: Sendable {
    /// Nil when the UID is not present or a read fails.
    var lookUp: @Sendable (_ uid: String) -> (id: AudioObjectID, device: InputDevice)?
    /// Creates the IOProc with `input.ring.context` and starts the device.
    var attach: @Sendable (_ input: DeviceInput) throws(HALError) -> Detach
}

/// Stops the device and destroys the IOProc. True when every call returned noErr. False: a late
/// call can still come, so the caller keeps the ring.
typealias Detach = @Sendable () -> Bool

enum HALError: Error, Hashable, Sendable {
    case status(OSStatus)
    case unsupportedFormat
    case undoFailed
}
