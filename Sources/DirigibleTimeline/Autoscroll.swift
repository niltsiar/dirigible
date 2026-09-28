/// The points that the lanes scroll in one display tick of a drag (decision 0025, U16). `x` is the
/// pointer in the lanes in view, 0 at their leading edge, and `width` their width. Inside nothing
/// scrolls; outside, 20 pt/s per point of distance, times a ramp min(4, 1 + `secondsInZone`), at
/// most 3000 pt/s. The 16 pt inner zone of an edge counts only when that edge touches the screen
/// edge, where the pointer cannot go past it. Negative: to the left.
/// ponytail: calibration values; manual check M4 tunes them.
public func autoscrollStep(
    x: Double, width: Double, edgesAtScreen: (leading: Bool, trailing: Bool), secondsInZone: Double, tick: Double
) -> Double {
    let zone = 16.0
    let (leading, trailing) = (edgesAtScreen.leading ? zone : 0, edgesAtScreen.trailing ? zone : 0)
    let distance =
        x > width - trailing ? x - (width - trailing) : x < leading ? x - leading : 0
    let speed = 20 * distance * min(4, 1 + secondsInZone)
    return min(max(speed, -3000), 3000) * tick
}
