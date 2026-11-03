import DirigibleCore

/// The read interface of the Player: one reading of the running play.
extension Player {
    /// `played` is the number of the last play that the Player started; `frame` is the position.
    /// `stop` is a stop that the user did not ask for; `faults` are the read faults of the feed.
    struct Reading: Sendable {
        var number: Int
        var played: Int
        var frame: Frames
        var ended: Bool
        /// The engine runs: a play started and no stop came.
        var running: Bool
        var stop: PlaybackStop?
        var faults: [FileID: MediaFault]
        /// The loudness of the heard frame (decision 0033).
        var loudness: LoudnessValues
        /// The output term of the last play start, or why it has none (decision 0070, **Anchor**).
        var term: Result<OutputTerm, OutputTermFault>
        /// The start host time of a take play in nanoseconds; nil for a plain play (0070).
        var realStart: UInt64?
    }
}
