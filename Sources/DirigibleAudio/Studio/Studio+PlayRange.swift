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
    case pastEnd(start: Frames, end: PlayEnd)
    /// A later transport command took the feed number during the awaits of the call.
    case superseded
    case failed(PlaybackStop)
}

/// The end of an agent play: the `to` of the call when it is before the session end, else the
/// session end.
public enum PlayEnd: Hashable, Sendable {
    case to(Frames)
    case session(Frames)

    var frame: Frames {
        switch self {
        case .to(let frame), .session(let frame): frame
        }
    }
}

extension Studio {
    /// Plays forward at 1x at the window speed from `from` (else the playhead) and stops at `to`
    /// (else the session end).
    public func play(from: Frames?, to: Frames?) async throws(StudioError) -> TransportOutcome {
        try checkNotBusy()
        try checkReadable(.play)
        return await playRange(from: from, to: to)
    }

    /// Moves the playhead to `frame`, as a click does. A play goes on from there in its shuttle.
    public func locate(_ frame: Frames) async throws(StudioError) -> TransportOutcome {
        try checkNotBusy()
        try checkReadable(.play)
        return await run(.seek(.frame(frame)))
    }

    /// Stops a play. It throws `.busy` only while a take starts, records, or finalizes, and never
    /// stops the take. Stopped, it gives the playhead.
    public func stopPlayback() async throws(StudioError) -> TransportOutcome {
        switch transport {
        case .recording, .finalizing: throw .busy
        default: guard !isStarting else { throw .busy }
        }
        guard play.playback != .stopped else { return .state(.stopped(at: play.playhead)) }
        return await run(.pause)
    }

    /// An agent play (C4, C4c, C5, C5b): forward 1x at the window speed from `from` (else the
    /// playhead of the last poll) to the smaller of `to` and the session end. A start at or after
    /// that end changes nothing.
    private func playRange(from: Frames?, to: Frames?) async -> TransportOutcome {
        let start = from ?? play.playhead
        let end = to.flatMap { $0 < session.end ? PlayEnd.to($0) : nil } ?? .session(session.end)
        guard start < end.frame else { return .pastEnd(start: start, end: end) }
        let forward = Shuttle(direction: .forward, rate: .one)
        let current = play.playback.shuttle
        if current == forward, from == nil, to == nil { return .state(state(from: play.playhead)) }
        let bound = to.map { min($0, session.end) }
        play.playback = .playing(forward)
        var number = play.feed + 1
        if current != nil {
            number = await endFeed(stop: false)
            guard play.feed == number else { return .superseded }
        } else {
            play.feed = number
        }
        // Before the media check: a user seek in the check keeps the end (C8, C18).
        (play.playhead, play.startPoint) = (start, start)
        play.end = bound.map { (number, $0) }
        guard current == nil else { return await startPlay(forward, from: start, number: number, end: bound) }
        return await startFromStopped(forward, number: number, end: bound)
    }
}
