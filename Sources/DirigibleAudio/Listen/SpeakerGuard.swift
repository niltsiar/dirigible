import CoreAudio
import os

/// The control state of the speaker guard of one ring: the devices with a data source listener,
/// and `closed`, which an off sets before it removes a listener.
struct WatchState: Sendable {
    var watched: Set<AudioObjectID> = []
    var closed = false
}

/// The speaker flag of a listen ring (decision 0044). A refresh reads the default output with the
/// rule of the banner and stores the flag in the ring, with no main actor hop. The HAL
/// notification thread runs it; it is not real-time, so the lock of the ring is allowed there.
/// No HAL call runs while the lock is held.
enum SpeakerGuard {
    /// Takes a ticket, reads the default output, watches it, reads its flag, and stores the flag
    /// when no newer ticket stored first. With no default output, the flag is true: the safe side.
    static func refresh(
        _ ring: ListenRing, output: () -> AudioObjectID?, watch: (AudioObjectID) -> Void,
        speakers: (AudioObjectID) -> Bool
    ) {
        let ticket = ring.nextTicket()
        let flag = output().map {
            AudioDefaults.read(output: $0, inputUID: nil, watch: watch, speakers: speakers).speakers
        }
        ring.storeSpeakers(flag ?? true, ticket: ticket)
    }

    /// Adds the data source listener of `ring` to `device` once, and never after `close`. When
    /// `close` runs during the add, this call removes its own add.
    static func watch(
        _ ring: ListenRing, _ device: AudioObjectID, add: (AudioObjectID) -> Bool, remove: (AudioObjectID) -> Void
    ) {
        let inserted = ring.watchState.withLock { state in
            guard !state.closed else { return false }
            return state.watched.insert(device).inserted
        }
        guard inserted else { return }
        guard add(device) else {
            _ = ring.watchState.withLock { $0.watched.remove(device) }
            return
        }
        if ring.watchState.withLock({ $0.closed }) { remove(device) }
    }

    /// Sets `closed`, then removes each data source listener. A second removal of one listener
    /// fails with no effect.
    static func close(_ ring: ListenRing, remove: (AudioObjectID) -> Void) {
        let devices = ring.watchState.withLock { state in
            state.closed = true
            return state.watched
        }
        for device in devices { remove(device) }
    }

    // MARK: Live HAL

    private static let defaultOutput = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
    private static let dataSource = propertyAddress(
        kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)

    /// Adds the default-output listener of `ring`, then reads the flag. The ring context is the
    /// client data, so it stays for the process life (0013 Detach). False when the add fails.
    static func open(_ ring: ListenRing) -> Bool {
        var address = defaultOutput
        let added = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject), &address, proc, ring.context)
        refresh(ring)
        return added == noErr
    }

    /// Removes the data source listeners of `ring`, then its default-output listener.
    static func close(_ ring: ListenRing) {
        close(ring) { removeDataSource($0, of: ring) }
        var address = defaultOutput
        _ = AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, proc, ring.context)
    }

    static func refresh(_ ring: ListenRing) {
        refresh(
            ring, output: { AudioDefaults.liveDefault(kAudioHardwarePropertyDefaultOutputDevice) },
            watch: { device in
                watch(
                    ring, device,
                    add: { device in
                        var address = dataSource
                        return AudioObjectAddPropertyListener(device, &address, proc, ring.context) == noErr
                    },
                    remove: { removeDataSource($0, of: ring) })
            }, speakers: AudioDefaults.liveSpeakers)
    }

    private static func removeDataSource(_ device: AudioObjectID, of ring: ListenRing) {
        var address = dataSource
        _ = AudioObjectRemovePropertyListener(device, &address, proc, ring.context)
    }

    /// The default-output listener and the data source listeners of one ring: a refresh.
    static let proc: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        SpeakerGuard.refresh(ListenRing(context: context))
        return noErr
    }
}
