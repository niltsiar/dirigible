import AVFoundation
import DirigibleCore

/// The loudness meter of the Player (decision 0033). It keeps the scheduled chunks of a 1x
/// forward play and feeds each chunk when the output has played it. So the values belong to the
/// heard frame, and a chunk that the output did not play never counts.
struct PlayerLoudness {
    private var meter: LiveLoudness?
    /// The chunks of the running 1x forward play that the output did not play yet, in order. The
    /// key is the end of the chunk in output frames from the play start. The node holds the same
    /// buffers, so the queue copies no audio.
    private var chunks: [(end: Int, buffer: AVAudioPCMBuffer)] = []
    /// True while a 1x forward play runs.
    private var metering = false
    /// The frame where the last 1x forward play stopped. Nil after a play at another shuttle.
    private var stopFrame: Frames?

    /// No meter under 3 364 Hz: the values stay `.none`.
    init(sampleRate: Int) { meter = LiveLoudness(sampleRate: sampleRate, layout: .stereo) }

    /// Tests only: the chunks in the queue.
    var queued: Int { chunks.count }

    /// M and S are nil while no 1x forward play runs. I and TP hold.
    var values: LoudnessValues {
        guard var values = meter?.values else { return .none }
        if !metering { (values.momentary, values.shortTerm) = (nil, nil) }
        return values
    }

    /// A play starts at `frame`. Only a 1x forward play at the speed 1 feeds the meter (0048). It
    /// adds to the values when it starts where the last 1x forward play stopped; else the values
    /// start again. A play at another shuttle or speed keeps the values.
    mutating func start(at frame: Frames, shuttle: Shuttle, speed: Double) {
        metering = shuttle == Shuttle(direction: .forward, rate: .one) && speed == 1
        if metering, frame != stopFrame { meter?.reset() }
        stopFrame = nil
    }

    /// The running play ends at `frame`, after `played` output frames. The chunks that the output
    /// did not play are dropped.
    mutating func stop(at frame: Frames, played: Int) {
        guard metering else { return }
        heard(played)
        chunks.removeAll()
        metering = false
        stopFrame = frame
    }

    /// The Player scheduled `chunk`, which ends at `end` output frames.
    mutating func scheduled(_ chunk: AVAudioPCMBuffer, end: Int) {
        if metering { chunks.append((end, chunk)) }
    }

    /// The output played `played` frames of the play: feeds each chunk that ends at or before it.
    mutating func heard(_ played: Int) {
        var fed = 0
        while fed < chunks.count, chunks[fed].end <= played {
            meter?.feed(chunks[fed].buffer)
            fed += 1
        }
        chunks.removeFirst(fed)
    }

    /// An underrun restarts the node at output frame 0, after it played the `scheduled` frames
    /// of the old feed. Feeds the chunks that end in them and empties the queue, so the keys of
    /// the next chunks start at 0.
    mutating func restart(scheduled: Int) {
        heard(scheduled)
        chunks.removeAll()
    }
}
