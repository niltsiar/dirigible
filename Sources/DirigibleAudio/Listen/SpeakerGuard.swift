import CoreAudio
import os

/// The control state of the speaker guard of one ring: the devices with device listeners,
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
    /// Takes a ticket, reads the default output and its active subdevices, watches each, reads
    /// the flag with the banner rule, and stores it when no newer ticket stored first. With no
    /// default output, the flag is true: the safe side.
    static func refresh(
        _ ring: ListenRing, output: () -> AudioObjectID?, subdevices: (AudioObjectID) -> [AudioObjectID] = { _ in [] },
        watch: (AudioObjectID) -> Void, speakers: (AudioObjectID) -> Bool
    ) {
        let ticket = ring.nextTicket()
        let flag = output().map {
            AudioDefaults.read(output: $0, inputUID: nil, subdevices: subdevices, watch: watch, speakers: speakers)
                .speakers
        }
        ring.storeSpeakers(flag ?? true, ticket: ticket)
    }

    /// Adds the device listeners of `ring` to `device` once, and never after `close`. When
    /// `close` runs during the add, this call removes its own add. A failed add fails closed: no
    /// listener tells the ring of a later change, so it plays zeros for good, and this returns
    /// false.
    @discardableResult static func watch(
        _ ring: ListenRing, _ device: AudioObjectID, add: (AudioObjectID) -> Bool, remove: (AudioObjectID) -> Void
    ) -> Bool {
        let inserted = ring.watchState.withLock { state in
            guard !state.closed else { return false }
            return state.watched.insert(device).inserted
        }
        guard inserted else { return true }
        guard add(device) else {
            _ = ring.watchState.withLock { $0.watched.remove(device) }
            ring.mute()
            return false
        }
        if ring.watchState.withLock({ $0.closed }) { remove(device) }
        return true
    }

    /// Sets `closed`, then removes the device listeners. A second removal of one listener
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
    /// The listeners of each watched device: a headphone plug changes the data source, and an
    /// aggregate change changes the active subdevices. A device with no such property takes the
    /// add too (probe P10).
    private static let deviceProperties = [
        propertyAddress(kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput),
        propertyAddress(kAudioAggregateDevicePropertyActiveSubDeviceList),
    ]

    /// Adds the default-output listener of `ring`, then reads the flag. The ring context is the
    /// client data, so it stays for the process life (0013 Detach). A failed add fails closed, as
    /// in `watch`: the ring plays zeros for good, and this returns false.
    static func open(_ ring: ListenRing) -> Bool {
        var address = defaultOutput
        let added =
            AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, proc, ring.context)
            == noErr
        if !added { ring.mute() }
        return refresh(ring) && added
    }

    /// Removes the device listeners of `ring`, then its default-output listener.
    static func close(_ ring: ListenRing) {
        close(ring) { removeListeners($0, of: ring) }
        var address = defaultOutput
        _ = AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, proc, ring.context)
    }

    /// The live refresh. False when a device listener add failed.
    @discardableResult static func refresh(_ ring: ListenRing) -> Bool {
        var added = true
        refresh(
            ring, output: { AudioDefaults.liveDefault(kAudioHardwarePropertyDefaultOutputDevice) },
            subdevices: AudioDefaults.liveSubdevices,
            watch: { device in
                added =
                    watch(
                        ring, device,
                        add: { device in
                            deviceProperties.allSatisfy { property in
                                var address = property
                                return AudioObjectAddPropertyListener(device, &address, proc, ring.context) == noErr
                            }
                        },
                        remove: { removeListeners($0, of: ring) }) && added
            }, speakers: AudioDefaults.liveSpeakers)
        return added
    }

    private static func removeListeners(_ device: AudioObjectID, of ring: ListenRing) {
        for property in deviceProperties {
            var address = property
            _ = AudioObjectRemovePropertyListener(device, &address, proc, ring.context)
        }
    }

    /// The default-output listener and the device listeners of one ring: a refresh.
    static let proc: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        SpeakerGuard.refresh(ListenRing(context: context))
        return noErr
    }
}
