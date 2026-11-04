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

/// The host time of the stop of a timed take (decision 0048, amended by 0070): the writer end +
/// the largest input latency of `devices` + 250 ms, so the frames in flight reach the writers.
func timedTakeStop(end: UInt64, devices: [InputDevice]) -> UInt64 {
    let latency = UInt64(devices.map(\.latencyNanos).max() ?? 0)
    let (stop, overflow) = end.addingReportingOverflow(latency + 250_000_000)
    return overflow ? .max : stop
}

/// The take mix of a pre-roll take (decision 0070, **Take mix**): `session` with the clips of the
/// armed tracks cleared from T. A T at or after the session end clears nothing.
func takeMix(_ session: Session, armed: [TrackID], from playhead: Frames) -> Session {
    guard playhead < session.end else { return session }
    var mix = session
    // An unknown track throws before a change, so the mix is then the session.
    try? mix.clear(playhead..<session.end, on: armed)
    return mix
}
