import DirigibleCore

/// The pre-roll start S of a take at `playhead`: `seconds` before it, and 0 at the earliest.
func preRollStart(playhead: Frames, seconds: Int, rate: Int) -> Frames {
    max(.zero, playhead - Frames(seconds * rate))
}

/// The take start host time H_T of a pre-roll take (decision 0070, **Anchor**): the host time
/// that frame S starts at (`realStart`), the output term, and the span from S to T.
func takeStartHostNanos(realStart: UInt64, term: OutputTerm, from start: Frames, to playhead: Frames, rate: Int)
    -> UInt64
{
    realStart + term.nanos(sessionRate: rate)
        + UInt64((Double((playhead - start).count) * 1e9 / Double(rate)).rounded())
}
