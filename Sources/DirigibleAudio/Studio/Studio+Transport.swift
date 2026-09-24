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
    /// The engine did not start; the value is the error code.
    case outputUnavailable(Int)
    /// The package left its volume or was deleted (decision 0016).
    case packageUnavailable
}

/// The playback state of a studio (decision 0016). `Studio` stores one value of it.
struct PlayState {
    var playback: Playback = .stopped
    /// At open: the session end, so Record in a reopened session appends. Not saved.
    var playhead: Frames
    /// Where Shift-Space goes: set by a play from stopped and by a seek.
    var startPoint: Frames
    /// From the media checks and the read faults of the Player.
    var missingMedia: [FileID: MediaFault]
    var playbackStop: PlaybackStop?
    /// The last feed number. Only a play, a stop, a seek, and a shuttle change take a new one.
    var feed = 0
    /// The last session revision sent to the Player. An edit takes a revision, not a feed number.
    var revision = 0
    /// Made at the first play from `environment.playerOutput`.
    var player: Player?
    /// Reads the Player every 33 ms while `playback` is `.playing`.
    var poll: Task<Void, Never>?

    init(at playhead: Frames, missingMedia: [FileID: MediaFault]) {
        self.playhead = playhead
        startPoint = playhead
        self.missingMedia = missingMedia
    }
}

extension Studio {
    public var playback: Playback { play.playback }
    /// Live while playing: the poll sets it every 33 ms.
    public var playhead: Frames { play.playhead }
    /// The pool files that give no frames or fewer frames. The clips of these files play as
    /// silence (decision 0003).
    public var missingMedia: [FileID: MediaFault] { play.missingMedia }
    /// The last stop of playback that the user did not ask for. A new play clears it.
    public var playbackStop: PlaybackStop? { play.playbackStop }

    /// Checks each pool file off the main actor (decision 0016). The window calls it at focus;
    /// `open`, a finalize, and a play from stopped check too. A package that left its volume
    /// keeps the last state: the check cannot read it.
    public func checkMedia() async {
        guard let faults = await mediaFaults(session, lock: lock, before: environment.beforeMediaCheck) else { return }
        play.missingMedia = faults
    }

    /// The one entry of the transport commands (decision 0016). It never throws: a command that
    /// the state refuses does nothing. While a take starts, records, or finalizes, only Space
    /// acts: it stops the take. A new feed number and `playback` change with no await first, so
    /// the next command sees them.
    public func perform(_ command: TransportCommand) async {
        if command == .playStop, case .recording = transport, !isStarting {
            try? await stopRecording()
            return
        }
        guard transport == .idle, !isStarting else { return }
        let current = play.playback.shuttle
        if case .seek(let seek) = command {
            guard let target = frame(of: seek) else { return }
            var number = play.feed + 1
            if current != nil { number = await endFeed(stop: false) } else { play.feed = number }
            guard play.feed == number else { return }
            (play.playhead, play.startPoint) = (target, target)
            if let current { await startPlay(current, from: target, number: number) }
            return
        }
        guard let next = Shuttle.after(command, current: current) else {
            var number = play.feed
            if current != nil {
                play.playback = .stopped
                number = await endFeed(stop: true)
            }
            if command == .stopAndReturn, play.feed == number { play.playhead = play.startPoint }
            return
        }
        guard next != current else { return }
        play.playback = .playing(next)
        guard current == nil else {
            let number = await endFeed(stop: false)
            if play.feed == number { await startPlay(next, from: play.playhead, number: number) }
            return
        }
        // A play from stopped with no frames in its direction changes nothing.
        guard next.direction == .forward ? play.playhead < session.end : play.playhead > .zero else {
            play.playback = .stopped
            return
        }
        play.feed += 1
        let number = play.feed
        play.startPoint = play.playhead
        play.playbackStop = nil
        // Only a play from stopped checks the media, not each shuttle key (plan gate 1 item 7).
        await checkMedia()
        // A stop, a seek, a shuttle change, or Record in the check makes this play old.
        guard play.feed == number else { return }
        await startPlay(next, from: play.playhead, number: number)
    }

    /// Tests only: pulls frames from the offline Player.
    func renderOffline(frames: Int) async -> [[Float]] { await play.player?.renderOffline(frames: frames) ?? [] }

    /// Stops a play and keeps the playhead where the Player stopped. Settle calls it.
    func stopPlay() async {
        guard play.playback != .stopped else { return }
        play.playback = .stopped
        _ = await endFeed(stop: true)
    }

    /// The first part of every take start, with no await (decision 0016): a new feed number
    /// and `.stopped`, so no play starts into the take. Returns the feed number of the play
    /// that it ended, or nil.
    func endPlayForTake() -> Int? {
        guard play.playback != .stopped else { return nil }
        let stopped = play.feed
        play.feed += 1
        play.playback = .stopped
        return stopped
    }

    /// The first step of a serialized take start: the Player stops, then the take playhead.
    /// That is `playhead`, or the Player position when the Player started the play that the
    /// take ended (`stopped`), or `play.playhead` (plan gate 2 item 1).
    func takePlayhead(_ stopped: Int?, _ playhead: Frames?) async -> Frames {
        if let player = play.player {
            await environment.beforePlayerStop()
            await player.apply(.stop, number: play.feed)
            let reading = await player.reading()
            if let stopped, reading.played == stopped { play.playhead = reading.frame }
        }
        return playhead ?? play.playhead
    }

    /// After a finalize that succeeds: the playhead goes to the largest end of the clips of the
    /// files that `finalized` adds. A punch-in split gives an old file a new clip ID, so a new
    /// clip ID alone does not mark a take clip.
    func takeEnded(_ finalized: Session) {
        let ends = finalized.tracks.flatMap(\.clips).filter { session.files[$0.file] == nil }.map(\.end)
        if let end = ends.max() { play.playhead = end }
    }

    /// A new player output drops a stopped Player; the next play makes one.
    func outputChanged() {
        assert(play.playback == .stopped, "the player output changed during a play")
        if play.playback == .stopped { play.player = nil }
    }

    /// Takes a new feed number for the end of the running feed. It sets the playhead to the
    /// Player position when the Player started that feed and no later command came. With
    /// `stop`, the Player stops first. Returns the new number.
    private func endFeed(stop: Bool) async -> Int {
        let stopped = play.feed
        play.feed += 1
        let number = play.feed
        guard let player = play.player else { return number }
        if stop { await player.apply(.stop, number: number) }
        let reading = await player.reading()
        if play.feed == number, reading.played == stopped { play.playhead = reading.frame }
        return number
    }

    /// Sends the session to the Player with a new revision and no feed number: the running feed
    /// goes on with the new session (plan gate 1 item 2). Each autosave calls it.
    func sendSession() {
        guard let player = play.player else { return }
        play.revision += 1
        let (session, revision) = (session, play.revision)
        Task { await player.update(session, revision: revision) }
    }

    private func startPlay(_ shuttle: Shuttle, from: Frames, number: Int) async {
        let player =
            play.player
            ?? Player(
                package: { [lock] in try lock.package() }, output: environment.playerOutput, session: session,
                start: environment.startEngine)
        play.player = player
        // Awaited, so a play after a take hears the take (plan gate 2 item 5).
        play.revision += 1
        await player.update(session, revision: play.revision)
        await player.apply(.play(from: from, shuttle: shuttle), number: number)
        guard play.poll == nil else { return }
        play.poll = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, await self.pollPlayer() else { return }
            }
        }
    }

    /// One poll: the playhead from the Player, and the end of the material. False ends the
    /// poll; the check and the clear have no await between, so a new play starts a new poll.
    private func pollPlayer() async -> Bool {
        if case .playing(let shuttle) = play.playback, let player = play.player {
            let number = play.feed
            let reading = await player.reading()
            if play.feed == number, reading.played == number {
                play.missingMedia.merge(reading.faults) { $1 }
                // The engine stops before the system posts the change, so its position can be
                // gone: the playhead keeps the last poll.
                if let stop = reading.stop ?? (reading.running ? nil : .outputChanged) {
                    play.playbackStop = stop
                    play.playback = .stopped
                    play.feed += 1
                    await player.apply(.stop, number: play.feed)
                } else if reading.ended {
                    // At 2x and 4x the Player position can pass the end by less than the rate.
                    play.playhead =
                        shuttle.direction == .forward ? min(reading.frame, session.end) : max(reading.frame, .zero)
                    play.playback = .stopped
                    play.feed += 1
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
        case .previousClip: session.edge(before: play.playhead)
        case .nextClip: session.edge(after: play.playhead)
        case .frame(let frame): max(.zero, frame)
        }
    }
}

/// The media check of `Studio.checkMedia`, off the main actor, in the package that the lock
/// holds now. Nil when the package left its volume or the process has no free descriptor.
@concurrent nonisolated func mediaFaults(
    _ session: Session, lock: PackageLock, before: @Sendable () -> Void
) async -> [FileID: MediaFault]? {
    before()
    guard let package = try? lock.package() else { return nil }
    return try? checkMedia(session, package: package)
}
