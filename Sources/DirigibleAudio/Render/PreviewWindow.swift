import DirigibleCore
import Foundation

/// The values that a measure of the de-clip depends on (decision 0064 C17): the file, the clip run
/// that the render measures, and the de-clip percent. The preview measures the de-clip alone, so a
/// rumble corner is not in the key.
struct PreviewMeasure: Hashable, Sendable {
    let file: FileID
    let run: Range<Frames>
    let declip: Int
}

/// The audio that a preview renders: frames `span` of `file`, the first `leadIn` of which the
/// preview drops, through one chain for each request of `levels`, bottom first. The chain also
/// reads `tail` frames past `span` and drops them, so a clipped run across the window end gets the
/// fill of the render. `tail` and `measure` are set only when the lowest level holds a de-clip.
struct PreviewWindow: Hashable, Sendable {
    let file: FileID
    let span: Range<Frames>
    let leadIn: Int
    var tail = 0
    let levels: [ClipRenderRequest]
    var measure: PreviewMeasure?
}

/// The window of a preview of `request` on `clip`, one of the clips `clips` of the request
/// (decision 0054). The levels are those of `levelRequests`, as the clip render builds them, at
/// any setting: a preview has no unchanged rule. On a clip with such levels, it reads the source
/// of the lowest one at the origin offset, so a preview never stacks; else the clip file. The
/// window is 10 s long, or the whole clip when the clip is shorter. It starts at `playhead` when it
/// is inside the clip, else at the clip start, and moves back when it would pass the clip end. It
/// reads up to 1 s of lead-in before the start, to the file start. With a de-clip in the lowest
/// level, it also reads up to 1 s of tail past the end, to the end of the clip run that the render
/// measures (0064 D9): the run of the first-level entry of `clipRenderPlan` that holds `clip`.
func previewWindow(
    of clip: ClipID, among clips: [ClipID], request: ClipRenderRequest, playhead: Frames, in session: Session
) throws(SessionError) -> PreviewWindow {
    guard let placed = session.clip(clip)?.clip else { throw .unknownClip(clip) }
    var source = session
    var levels = [request]
    if let rebuilt = levelRequests(request, on: session.origins(of: clip).map(\.treatment)) {
        try source.lower([clip], levels: rebuilt.lowest + 1)
        levels = rebuilt.requests
    }
    guard let lowered = source.clip(clip)?.clip else { throw .unknownClip(clip) }
    let rate = session.sampleRate
    let length = min(10 * rate, lowered.length.count)
    let wanted = lowered.offset + (placed.range.contains(playhead) ? playhead - placed.start : .zero)
    let start = Frames(min(wanted.count, (lowered.offset + lowered.length).count - length))
    let end = start + Frames(length)
    let leadIn = min(start.count, rate)
    let lowest = levels[0].treatment
    var window = PreviewWindow(file: lowered.file, span: (start - Frames(leadIn))..<end, leadIn: leadIn, levels: levels)
    if let declip = lowest.declip {
        let plan = try clipRenderPlan(clips, request: request, in: session)
        let runs = try plan.lowered.clipRuns(of: plan.levels.first?.first { $0.clips.contains(clip) }?.clips ?? [])
        let run = runs.first { $0.clips.contains(clip) }?.span ?? end..<end
        window.tail = min(rate, max(0, (run.upperBound - end).count))
        window.measure = PreviewMeasure(file: lowered.file, run: run, declip: declip.percent)
    }
    return window
}
