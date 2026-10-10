/// The drift rule of a listen ring (decision 0044). It keeps the fill of the ring near a target
/// with two clocks and no aggregate device: it drops or repeats one frame per render. Only the
/// render mutates it, so it is a plain value with no allocation, lock, or atomic.
///
/// The signal is the minimum, over a tumbling window of 1 s of pulled frames, of the fill after
/// each pop plus the signed corrections so far (a drop is +1, a repeat is -1). At the window end,
/// the error is that minimum minus the corrections now, minus the target. An error outside the
/// band replaces the pending correction, and an error inside the band clears it. An error more
/// than `skipOver` over the target skips to the target at once (probe P3b: a render gap).
struct DriftRule {
    /// What one render does with the ring.
    enum Pull: Equatable {
        /// Zeros, and no frame leaves the ring: the prime waits, or the ring ran dry.
        case silence(underrun: Bool)
        /// Discard `skip` frames, then read `read` frames for the frames of the call: one more is
        /// a drop, one less a repeat.
        case play(skip: Int, read: Int)
    }

    struct Counts: Equatable {
        var underruns = 0
        var skips = 0
        var drops = 0
        var repeats = 0
        var windows = 0
    }

    /// The largest push and pull of this rule, at the input rate.
    let inputBlock: Int
    let pullBlock: Int
    let rate: Double
    /// The fill after a pop that the rule keeps: one block plus 2 ms, so one pull interval with
    /// no push (a phase crossing of two clocks) leaves 2 ms.
    let target: Int
    let band: Int
    let skipOver: Int
    /// The window length in pulled frames: 1 s.
    let window: Int
    private(set) var counts = Counts()
    /// The error of the last window end.
    private(set) var lastError: Int?
    private var primed = false
    private var corrections = 0
    private var pending = 0
    private var windowMinimum = Int.max
    private var windowFrames = 0

    init(inputBlock: Int, pull: Int, rate: Double) {
        self.inputBlock = inputBlock
        pullBlock = pull
        self.rate = rate
        let block = max(inputBlock, pull)
        let millisecond = rate / 1000
        target = block + Int((2 * millisecond).rounded())
        band = Int(millisecond.rounded())
        skipOver = block + Int((8 * millisecond).rounded())
        window = Int(rate.rounded())
    }

    /// One render of `frames` with `available` frames in the ring. `pushed` is the frame count of
    /// the last push. A push or a pull over the sizes of the rule makes a new rule with the
    /// larger size, which primes again.
    mutating func pull(frames: Int, available: Int, pushed: Int) -> Pull {
        // A render of no frames: with a repeat pending, the read would be -1 frames.
        guard frames > 0 else { return .play(skip: 0, read: 0) }
        if pushed > inputBlock || frames > pullBlock {
            let counts = counts
            self = DriftRule(inputBlock: max(inputBlock, pushed), pull: max(pullBlock, frames), rate: rate)
            self.counts = counts
        }
        guard primed else { return prime(frames: frames, available: available) }
        let step = pending.signum()
        let read = frames + step
        guard available >= read else {
            primed = false
            counts.underruns += 1
            return .silence(underrun: true)
        }
        pending -= step
        corrections += step
        if step > 0 { counts.drops += 1 } else if step < 0 { counts.repeats += 1 }
        windowMinimum = min(windowMinimum, available - read + corrections)
        windowFrames += frames
        guard windowFrames >= window else { return .play(skip: 0, read: read) }
        let error = windowMinimum - corrections - target
        windowMinimum = .max
        windowFrames = 0
        counts.windows += 1
        lastError = error
        if error > skipOver {
            counts.skips += 1
            pending = 0
            return .play(skip: error, read: read)
        }
        pending = abs(error) > band ? error : 0
        return .play(skip: 0, read: read)
    }

    /// Zeros until the fill is the target plus one input block. That pop leaves the target plus
    /// one input block minus the pull, so the next minimum is near the target.
    private mutating func prime(frames: Int, available: Int) -> Pull {
        guard available >= target + inputBlock else { return .silence(underrun: false) }
        primed = true
        pending = 0
        windowMinimum = .max
        windowFrames = 0
        return .play(skip: available - target - inputBlock, read: frames)
    }
}
