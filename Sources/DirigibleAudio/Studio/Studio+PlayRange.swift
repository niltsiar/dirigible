import DirigibleCore

/// The transport state after a call: stopped at a frame, or a play from a frame to its end in a
/// shuttle. `to` is 0 for a reverse play, else the end of the play or the session end.
public enum TransportState: Hashable, Sendable {
    case stopped(at: Frames)
    case playing(from: Frames, to: Frames, shuttle: Shuttle)
}

/// The result of an agent transport call, built in the call after its last await.
public enum TransportOutcome: Hashable, Sendable {
    case state(TransportState)
    /// The start is at or after the end of the play: nothing changed.
    case pastEnd(start: Frames, end: Frames)
    /// A later transport command took the feed number during the awaits of the call.
    case superseded
    case failed(PlaybackStop)
}

/// A request of the `run` core of the transport: a command of the window or the keys, or an
/// agent play with an end.
enum TransportRequest: Hashable, Sendable {
    case command(TransportCommand)
    case playRange(from: Frames?, to: Frames?)
}

extension Studio {
    /// Plays forward at 1x at the window speed from `from` (else the playhead) and stops at `to`
    /// (else the session end).
    public func play(from: Frames?, to: Frames?) async throws(StudioError) -> TransportOutcome {
        try checkIdle()
        return await run(.playRange(from: from, to: to))
    }

    /// Moves the playhead to `frame`, as a click does. A play goes on from there in its shuttle.
    public func locate(_ frame: Frames) async throws(StudioError) -> TransportOutcome {
        try checkIdle()
        return await run(.command(.seek(.frame(frame))))
    }

    /// Stops a play. It throws `.busy` only while a take starts, records, or finalizes, and never
    /// stops the take. Stopped, it gives the playhead.
    public func stopPlayback() async throws(StudioError) -> TransportOutcome {
        switch transport {
        case .recording, .finalizing: throw .busy
        default: guard !isStarting else { throw .busy }
        }
        guard play.playback != .stopped else { return .state(.stopped(at: play.playhead)) }
        return await run(.command(.pause))
    }
}

/// The media check of `Studio.checkMedia` and `Studio.exportFaults`, off the main actor, in the
/// package that the lock holds now. Nil when the package left its volume or the process has no
/// free descriptor.
@concurrent nonisolated func mediaFaults(
    _ session: Session, lock: PackageLock, source: ExportSource? = nil, before: @Sendable () async -> Void = {}
) async -> [FileID: MediaFault]? {
    await before()
    guard let package = try? lock.package() else { return nil }
    return try? checkMedia(session, package: package, source: source)
}
