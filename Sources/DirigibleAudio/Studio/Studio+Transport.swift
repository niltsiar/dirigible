import DirigibleCore
import Foundation

public enum Playback: Hashable, Sendable {
    case stopped
    case playing(Shuttle)

    var shuttle: Shuttle? {
        if case .playing(let shuttle) = self { return shuttle }
        return nil
    }
}

/// A stop of playback that the user did not ask for.
public enum PlaybackStop: Hashable, Sendable {
    /// The output device changed or went away. The user presses Space again.
    case outputChanged
    /// The engine did not start, or the paced output did not render; the value is the error code
    /// or the render status.
    case outputUnavailable(Int)
    /// The package left its volume or was deleted (decision 0016).
    case packageUnavailable
    /// An audio file did not open because the process had no free descriptor; the value is the
    /// errno (EMFILE or ENFILE). It is not a fault of the file (decision 0016).
    case noFreeDescriptor(Int)
}

extension Studio {
    /// True when no take, placement, level, duck, match, silence scan, sync, import, or package job runs, and no
    /// take starts.
    public var isIdle: Bool { transport == .idle && !isStarting }

    /// Edits and a new take wait during a take (0004), a placement (0021), a level (0031), a duck
    /// (0060), a voice match (0074), a silence scan (0066), a sync (0076), an import (0040), or a package job (0072).
    /// They also wait during `settle()`, so an agent edit that gets OK
    /// is on disk before its window closes (decision 0046). A take marker and its save run during a
    /// take (F107). Each write job calls it, so a job that no list names refuses an archived session
    /// with `.archived` after the busy test (decision 0072); a read calls `checkNotBusy()`.
    func checkIdle() throws(StudioError) {
        try checkNotBusy()
        guard !isArchived else { throw .archived }
    }

    /// Refuses a ripple under a pending or split take (decision 0037).
    func checkRipple() throws(StudioError) {
        guard canRipple else { throw .rippleBlocked }
    }
}

extension Studio {
    /// Checks each pool file off the main actor (decision 0016). The window calls it at focus;
    /// `open`, a finalize, and a play from stopped check too. A package that left its volume
    /// keeps the last state: the check cannot read it. It does not start during a package job,
    /// which renames the clip files (decision 0072).
    public func checkMedia() async {
        guard archiveRun == nil else { return }
        guard let faults = await mediaFaults(session, lock: lock, before: environment.beforeMediaCheck) else { return }
        missingMedia = faults
    }

    /// The transport commands of the window and the keys (decision 0016). It never throws: a
    /// command that the state refuses does nothing.
    public func perform(_ command: TransportCommand) async {
        _ = await run(command)
    }

    /// A transport command of `perform`, `locate(_:)`, or `stopPlayback()` (decision 0016). The
    /// agent play `playRange` is the other path: both end a running feed with `endFeed`, start a
    /// feed with `startPlay`, and keep an end with its feed number in `PlayState.end`. While a
    /// take starts, records, or finalizes, only Space acts: it stops the take. A new feed number
    /// and `playback` change with no await first, so the next request sees them. Each outcome is
    /// built after the last await, with a check of the feed number and no await between.
    func run(_ command: TransportCommand) async -> TransportOutcome {
        if command == .playStop, case .recording = transport, !isStarting {
            try? await stopRecording()
            return .state(.stopped(at: play.playhead))
        }
        guard isIdle else { return .state(state(from: play.playhead)) }
        let current = play.playback.shuttle
        if case .seek(let seek) = command {
            guard let target = frame(of: seek) else { return .state(state(from: play.playhead)) }
            // Read before `endFeed` takes the new number, which drops the end. No clamp: the Player
            // clamps, and an undo can move the session end back after the bound (C8).
            let bound = play.bound
            // A forward play stops at a target at or after the session end (C7).
            let stops = current?.direction == .forward && target >= session.end
            var number = play.feed + 1
            if current != nil {
                if stops { play.playback = .stopped }
                number = await endFeed(stop: stops)
            } else {
                play.feed = number
            }
            guard play.feed == number else { return .superseded }
            (play.playhead, play.startPoint) = (target, target)
            guard let current, !stops else { return .state(.stopped(at: target)) }
            let end = bound.flatMap { target < $0 ? $0 : nil }
            play.end = end.map { (number, $0) }
            return await startPlay(current, from: target, number: number, end: end)
        }
        guard let next = Shuttle.after(command, current: current) else {
            var number = play.feed
            if current != nil {
                play.playback = .stopped
                number = await endFeed(stop: true)
            }
            guard play.feed == number else { return .superseded }
            if command == .stopAndReturn { play.playhead = play.startPoint }
            return .state(.stopped(at: play.playhead))
        }
        guard next != current else { return .state(state(from: play.playhead)) }
        play.playback = .playing(next)
        guard current == nil else {
            let number = await endFeed(stop: false)
            guard play.feed == number else { return .superseded }
            return await startPlay(next, from: play.playhead, number: number, end: nil)
        }
        // A play from stopped with no frames in its direction changes nothing.
        guard next.direction == .forward ? play.playhead < session.end : play.playhead > .zero else {
            play.playback = .stopped
            return .state(.stopped(at: play.playhead))
        }
        play.feed += 1
        let number = play.feed
        play.startPoint = play.playhead
        return await startFromStopped(next, number: number, end: nil)
    }

    /// A play from stopped: the media check, then the feed `number` from the playhead.
    func startFromStopped(_ shuttle: Shuttle, number: Int, end: Frames?) async -> TransportOutcome {
        play.playbackStop = nil
        // Only a play from stopped checks the media, not each shuttle key (plan gate 1 item 7).
        await checkMedia()
        // A stop, a seek, a shuttle change, or Record in the check makes this play old.
        guard play.feed == number else { return .superseded }
        return await startPlay(shuttle, from: play.playhead, number: number, end: end)
    }

    /// The state that plays now, from `start`. The end of a reverse play is 0.
    func state(from start: Frames) -> TransportState {
        guard let shuttle = play.playback.shuttle else { return .stopped(at: play.playhead) }
        let end = shuttle.direction == .reverse ? .zero : playEnd ?? session.end
        return .playing(from: start, to: end, shuttle: shuttle)
    }

    /// The end of the running play, at most the session end: the Player stops at an edit that
    /// moves the session end before it (C8).
    private var playEnd: Frames? { play.bound.map { min($0, session.end) } }

    /// A speed change now acts: no take starts, records, or finalizes, and the unit exists. The
    /// window reads it to store the last speed before the change (decision 0052).
    public var takesSpeedChange: Bool { isIdle && canChangeSpeed }

    /// Sets the vari-speed (decision 0052). It does nothing during a take or when the unit does
    /// not load. Stopped or at a tape rate, a change sets only the next 1x play. During a 1x play
    /// the play goes on from the heard frame: a change between two speeds other than 1 sets only
    /// the rate of the unit, except in a play with an end, which plays again with no end (C8);
    /// another change is a new play, as a shuttle change (S6). The speed changes with no await
    /// first, as a feed number does in `run`.
    public func changeSpeed(to new: Speed) async {
        let old = play.speed
        guard takesSpeedChange, new != old else { return }
        play.speed = new
        guard let shuttle = play.playback.shuttle, shuttle.rate == .one else { return }
        if old != .one, new != .one, play.bound == nil, let player = play.player {
            let before = play.feed
            if await player.setSpeed(new) { return }
            // A stop, a seek, or Record in the await ended this play: no new play.
            guard play.feed == before, isIdle else { return }
        }
        let number = await endFeed(stop: false)
        if play.feed == number { _ = await startPlay(shuttle, from: play.playhead, number: number, end: nil) }
    }

    /// Tests only: pulls frames from the offline Player.
    func renderOffline(frames: Int) async -> [[Float]] { await play.player?.renderOffline(frames: frames) ?? [] }

    /// Stops a play and keeps the playhead where the Player stopped. Settle calls it.
    func stopPlay() async {
        guard play.playback != .stopped else { return }
        play.playback = .stopped
        _ = await endFeed(stop: true)
    }

    /// The first part of every take start and blocking run, with no await (decision 0016): the
    /// effect preview stops, and a new feed number and `.stopped`, so no play starts into the take.
    /// Returns the feed number of the play that it ended, or nil.
    func endPlayForTake() -> Int? {
        stopEffectPreview()
        guard play.playback != .stopped else { return nil }
        let stopped = play.feed
        play.feed += 1
        play.playback = .stopped
        holdLoudness()
        return stopped
    }

    /// The first step of a serialized take start: the Player stops, then the take playhead.
    /// That is `playhead`, or the Player position when the Player started the play that the
    /// take ended (`stopped`), or `play.playhead` (plan gate 2 item 1).
    func takePlayhead(_ stopped: Int?, _ playhead: Frames?) async -> Frames {
        if let player = play.player {
            let span = environment.log.begin(.take, "play-stop-begin")
            await environment.beforePlayerStop()
            await player.apply(.stop, number: play.feed)
            span.end("play-stop")
            let reading = await player.reading()
            if let stopped, reading.played == stopped { play.playhead = reading.frame }
        }
        return playhead ?? play.playhead
    }

    /// After a finalize that succeeds: the playhead goes to the largest end of the take clips.
    func takeEnded(_ finalized: Session) {
        let ends = takeClips(of: finalized, before: session).map(\.end)
        if let end = ends.max() { play.playhead = end }
        handOffLive(finalized)
    }

    /// A new player output drops a stopped Player; the next play makes one.
    func outputChanged() {
        assert(play.playback == .stopped, "the player output changed during a play")
        if play.playback == .stopped { play.player = nil }
    }

    /// Takes a new feed number for the end of the running feed. It sets the playhead to the
    /// Player position when the Player started that feed and no later command came. With
    /// `stop`, the Player stops first. Returns the new number.
    func endFeed(stop: Bool) async -> Int {
        let stopped = play.feed
        play.feed += 1
        let number = play.feed
        guard let player = play.player else { return number }
        if stop { await player.apply(.stop, number: number) }
        let reading = await player.reading()
        if play.feed == number, reading.played == stopped {
            play.playhead = reading.frame
            loudness = reading.loudness
        }
        if stop { holdLoudness() }
        return number
    }

    /// A stop holds I and TP; M and S need a running 1x forward play (decision 0033).
    private func holdLoudness() {
        (loudness.momentary, loudness.shortTerm) = (nil, nil)
    }

    /// Sends the session to the Player with a new revision and no feed number: the running feed
    /// goes on with the new session (plan gate 1 item 2). Each autosave calls it. A newer
    /// revision replaces the session of the Player.
    func sendSession() {
        guard let player = play.player else { return }
        var session = playerSession
        // An edit during a drag sends the session again: the Player keeps the dragged gain.
        if let preview = play.preview { try? session.setGain(preview.gain, track: preview.track) }
        if let preview = play.matchPreview { try? session.setMatchAmount(preview.amount, tracks: [preview.track]) }
        play.revision += 1
        let revision = play.revision
        Task { await player.update(session, revision: revision) }
    }

    /// Plays `gain` on `track` during play, with no edit and no autosave: the drag of the track
    /// fader (F94). The mouse-up makes the one edit, then `endPreview` ends the preview. Stopped,
    /// it sends nothing, so the next play starts from the session.
    public func previewGain(_ gain: Gain, track: TrackID) throws(StudioError) {
        try checkNotBusy()
        try checkReadable(.play)
        guard play.playback != .stopped else { return }
        var checked = session
        do { try checked.setGain(gain, track: track) } catch { throw .session(error) }
        play.preview = (track, gain)
        sendSession()
    }

    /// Ends the preview of a drag of a fader or a match amount. When the session value differs from
    /// the preview value, it sends the session again. After the edit of a mouse-up the Player has the session already.
    public func endPreview() {
        if let preview = play.matchPreview {
            play.matchPreview = nil
            if session.track(preview.track)?.match?.amount != preview.amount { sendSession() }
        }
        guard let preview = play.preview else { return }
        play.preview = nil
        if session.track(preview.track)?.gain != preview.gain { sendSession() }
    }

    /// The Player of the first play, with the seams of `environment`.
    func makePlayer() -> Player {
        Player(
            package: { [lock] in try lock.package() }, output: environment.playerOutput, session: session,
            start: environment.startEngine, speedUnit: environment.speedUnit, readTerm: environment.outputTerm,
            hostNanos: environment.hostNanos)
    }

    /// Starts the feed `number`, then takes one reading of the Player as the poll does.
    func startPlay(_ shuttle: Shuttle, from: Frames, number: Int, end: Frames?) async -> TransportOutcome {
        stopEffectPreview()
        let player = play.player ?? makePlayer()
        play.player = player
        // Awaited, so a play after a take hears the take (plan gate 2 item 5).
        play.revision += 1
        await player.update(session, revision: play.revision)
        await player.apply(.play(from: from, shuttle: shuttle, speed: play.speed, end: end), number: number)
        let reading = await player.reading()
        if reading.played == number, case .failure(let fault) = reading.term {
            environment.log.note(.device, "output-term-fault", level: .error, fields: fault.journalFields)
        }
        if play.feed == number, reading.played == number, let stop = accept(reading) {
            await player.apply(.stop, number: play.feed)
            return .failed(stop)
        }
        if play.poll == nil {
            play.poll = Task { [weak self] in
                while true {
                    try? await Task.sleep(for: .milliseconds(33))
                    guard let self, await self.pollPlayer() else { return }
                }
            }
        }
        guard play.feed == number else { return .superseded }
        return .state(state(from: from))
    }

    /// Takes a reading of the running feed, for the poll and a play start: the loudness and the
    /// media faults, then the fault rule. A stop that the user did not ask for, or an engine that
    /// does not run, ends the play with no await and returns the cause; the caller stops the
    /// Player.
    private func accept(_ reading: Player.Reading) -> PlaybackStop? {
        // Each branch of the poll keeps the last values: a play that ends before a poll ran has its I.
        loudness = reading.loudness
        // Only a fault writes: the view of the lanes reads `missingMedia` (decision 0017).
        if !reading.faults.isEmpty { missingMedia.merge(reading.faults) { $1 } }
        guard let stop = reading.stop ?? (reading.running ? nil : .outputChanged) else { return nil }
        play.playbackStop = stop
        play.playback = .stopped
        play.feed += 1
        holdLoudness()
        return stop
    }

    /// One poll: the playhead from the Player, and the end of the material. False ends the
    /// poll; the check and the clear have no await between, so a new play starts a new poll.
    private func pollPlayer() async -> Bool {
        if case .playing(let shuttle) = play.playback, let player = play.player {
            let number = play.feed
            let reading = await player.reading()
            if play.feed == number, reading.played == number {
                // The engine stops before the system posts the change, so its position can be
                // gone: the playhead keeps the last poll.
                if accept(reading) != nil {
                    await player.apply(.stop, number: play.feed)
                } else if reading.ended {
                    // At 2x and 4x the Player position can pass the end by less than the rate.
                    play.playhead =
                        shuttle.direction == .forward ? min(reading.frame, session.end) : max(reading.frame, .zero)
                    play.playback = .stopped
                    play.feed += 1
                    holdLoudness()
                    await player.apply(.stop, number: play.feed)
                } else {
                    play.playhead = reading.frame
                }
            }
        }
        if play.playback != .stopped { return true }
        play.poll = nil
        return false
    }

    private func frame(of seek: Seek) -> Frames? {
        switch seek {
        case .start: .zero
        case .end: session.end
        case .previousClip: session.edge(before: previousFrom)
        case .nextClip: session.edge(after: play.playhead)
        case .frame(let frame): max(.zero, frame)
        }
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
