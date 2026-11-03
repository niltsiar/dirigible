import DirigibleCore
import Foundation

/// The playback state of a studio (decision 0016). `Studio` stores one value of it.
struct PlayState {
    var playback: Playback = .stopped
    /// At open: the session end, so Record in a reopened session appends. Not saved.
    var playhead: Frames {
        didSet { playheadTime = .now }
    }
    /// The instant of the last write of `playhead`: a poll, a seek, or a stop. The timeline draws
    /// the playhead line from it between two polls (decision 0017).
    var playheadTime = ContinuousClock.now
    /// Where Shift-Space goes: set by a play from stopped and by a seek.
    var startPoint: Frames
    var playbackStop: PlaybackStop?
    /// The last feed number. Only a play, a stop, a seek, and a shuttle change take a new one.
    var feed = 0
    /// The end of a play that `Studio.play(from:to:)` started, with the feed number that it
    /// belongs to. Only that call and a seek before the end set it.
    var end: (feed: Int, frame: Frames)?
    /// The last session revision sent to the Player. An edit takes a revision, not a feed number.
    var revision = 0
    /// The gain of a fader drag: each session that the Player gets has it, until `endPreview`.
    var preview: (track: TrackID, gain: Gain)?
    /// The armed tracks and T of a pre-roll take from its take play start to its end: each
    /// session that the Player gets is the take mix (decision 0070).
    var takeMix: (armed: [TrackID], from: Frames)?
    /// The vari-speed of a 1x play (decision 0052): window state, 1x at open.
    var speed = Speed.one
    /// Made at the first play from `environment.playerOutput`.
    var player: Player?
    /// Reads the Player every 33 ms while `playback` is `.playing`.
    var poll: Task<Void, Never>?

    /// The end of the running play: valid only while the feed number is the one that set it, so
    /// each new feed number that sets no end drops it.
    var bound: Frames? { end?.feed == feed ? end?.frame : nil }

    init(at playhead: Frames) {
        self.playhead = playhead
        startPoint = playhead
    }
}

extension Studio {
    public var playback: Playback { play.playback }
    /// Live while playing: the poll sets it every 33 ms.
    public var playhead: Frames { play.playhead }
    /// The instant of the last poll or set of `playhead`.
    public var playheadTime: ContinuousClock.Instant { play.playheadTime }
    /// The last stop of playback that the user did not ask for. A new play clears it.
    public var playbackStop: PlaybackStop? { play.playbackStop }
    /// The vari-speed of a 1x play (decision 0052).
    public var speed: Speed { play.speed }
    /// The system has the speed unit; else the speed stays 1 (decision 0052). One lookup for each
    /// environment, with no instance, so the main actor loads no audio unit.
    public var canChangeSpeed: Bool {
        if let found = speedUnitFound { return found }
        let found = environment.speedUnit() != nil
        speedUnitFound = found
        return found
    }
    /// The frame that Previous Clip and Previous Marker look before. During play it is 0.5 s
    /// before the playhead: the playhead is past an edge or a marker when the user hears it, so
    /// a press just after it goes to the one before it (code gate 1).
    public var previousFrom: Frames {
        play.playback == .stopped ? play.playhead : play.playhead - Frames(session.sampleRate / 2)
    }
}
