import DirigibleCore

public enum StudioError: Error, Hashable, Sendable {
    /// A take records or finalizes, or a new take waits for a pending take.
    case busy
    /// Another studio or the CLI has the package.
    case locked
    /// The armed track has no route.
    case noRoute(TrackID)
    /// The route of the armed track names a device that is not in the list.
    case deviceMissing(TrackID)
    /// The route of the armed track names a channel that the device does not have.
    case channelOutOfRange(TrackID)
    /// Two armed tracks route the same device channel: the first track and the second.
    case channelInUse(TrackID, TrackID)
    case session(SessionError)
    case file(SessionFileError)
    case finalize(FinalizeError)
    /// The front end requests the access and starts again (decision 0013).
    case microphoneAccess(MicrophoneAccess)
    /// Less than 1 GB is free (decision 0004).
    case diskLow
}
