import AudioToolbox
import DirigibleCore
import Foundation

/// The renders of one request (decision 0057): for each clip, the levels of `levelRequests`, or
/// one new level on top when no level holds a kind that the request sets or removes. So each kind
/// is in one level at most.
struct ClipRenderPlan {
    /// The session with each clip of `levels` moved below the lowest level that it renders again.
    /// Each other clip keeps its file, offset, gain, and envelope.
    let lowered: Session
    /// The renders in order. Each level holds one entry for each distinct request of its clips.
    let levels: [[(clips: [ClipID], request: ClipRenderRequest)]]
    /// The clips that need no render.
    let unchanged: [ClipID]
}

/// The plan of `request` on `clips`. A clip is unchanged when the request equals the stored
/// effects of its lowest level (`ClipRenderRequest.isUnchanged(from:)`), no level above holds a kind
/// that the request sets or removes, and its file covers the
/// span with handles that `clipRuns` gives for it on the source of that level. So a trim in, a
/// split half, or a deleted middle needs no render, and a trim out to the edge of the rendered file
/// renders again. It throws the refusals of `Session.lower`.
func clipRenderPlan(
    _ clips: [ClipID], request: ClipRenderRequest, in session: Session
) throws(SessionError) -> ClipRenderPlan {
    let touched = request.touched
    var lowered = session
    var renders: [(clip: ClipID, requests: [ClipRenderRequest])] = []
    var unchanged: [ClipID] = []
    var seen: Set<ClipID> = []
    for clip in clips where seen.insert(clip).inserted {
        let chain = session.origins(of: clip)
        guard let rebuilt = levelRequests(request, of: clip, in: session) else {
            renders.append((clip, [request]))
            continue
        }
        let (lowest, requests) = rebuilt
        var below = lowered
        try below.lower([clip], levels: lowest + 1)
        if request.isUnchanged(from: chain[lowest].treatment),
            !chain[..<lowest].contains(where: { $0.treatment.effects.contains { touched.contains($0.kind) } }),
            let file = session.clip(clip)?.clip.file, let length = session.files[file]?.length
        {
            // The frames of the file of the clip, in the frames of the source of the level.
            let start = chain[...lowest].reduce(Frames.zero) { $0 + $1.offset }
            let span = try below.clipRuns(of: [clip])[0].span
            if start <= span.lowerBound, span.upperBound <= start + length {
                unchanged.append(clip)
                continue
            }
        }
        lowered = below
        renders.append((clip, requests))
    }
    let depth = renders.map(\.requests.count).max() ?? 0
    let levels = (0..<depth).map { index in
        var entries: [(clips: [ClipID], request: ClipRenderRequest)] = []
        for render in renders where index < render.requests.count {
            let request = render.requests[index]
            if let at = entries.firstIndex(where: { $0.request == request }) {
                entries[at].clips.append(render.clip)
            } else {
                entries.append(([render.clip], request))
            }
        }
        return entries
    }
    return ClipRenderPlan(lowered: lowered, levels: levels, unchanged: unchanged)
}

/// The levels that a render of `request` on `clip` builds again (decision 0057 D4), or nil when no
/// level of the origin chain holds a kind that the request sets or removes: then the render puts a
/// new level on top. `lowest` is the index in `session.origins(of: clip)` of the lowest level with
/// such a kind. `requests` are, bottom first, that level with `ClipRenderRequest(stored)
/// .replacing(with: request)` and each level above with `removing(request.touched)`; a level with
/// no effect left goes. `clipRenderPlan` and the preview window call it; only `clipRenderPlan`
/// applies the unchanged rule.
func levelRequests(
    _ request: ClipRenderRequest, of clip: ClipID, in session: Session
) -> (lowest: Int, requests: [ClipRenderRequest])? {
    let touched = request.touched
    let chain = session.origins(of: clip)
    // Top level first, so the lowest level of a touched kind is the last match.
    guard let lowest = chain.lastIndex(where: { $0.treatment.effects.contains { touched.contains($0.kind) } })
    else { return nil }
    let above = chain[..<lowest].reversed().compactMap { ClipRenderRequest($0.treatment).removing(touched) }
    return (lowest, [ClipRenderRequest(chain[lowest].treatment).replacing(with: request)] + above)
}

/// Renders the levels of `plan` in order, with one `renderClips` call for each entry: two
/// requests in one run of one file cannot share a call (`.mixedTreatments`). One space check
/// before the first call, for the bytes of the first level times the number of levels; each later
/// call checks no space. The progress only rises: each call gets the band of its run frames in
/// the frames of that bound, and 1 comes once, after the last call. A throw removes the files of
/// each earlier call. A plan with no level gives `plan.lowered` and no file.
func renderLevels(
    _ plan: ClipRenderPlan, in package: URL, freeBytes: () -> Int64,
    component: (Int) -> AudioComponentDescription = { _ in .soundIsolation }, readFault: ReadFault? = nil,
    isDownloaded: (URL) -> Bool = sourceIsDownloaded, progress: @escaping (Double) -> Void = { _ in },
    isCancelled: @escaping () -> Bool = { false }
) throws(ClipRenderError) -> ClipRenderOutcome {
    guard let first = plan.levels.first else {
        return ClipRenderOutcome(session: plan.lowered, made: [], clips: [], unchanged: plan.unchanged)
    }
    var bound = (frames: Int64(0), bytes: Int64(0))
    for entry in first {
        let size = try runSize(entry.clips, in: plan.lowered)
        bound = (bound.frames + size.frames, bound.bytes + size.bytes)
    }
    let total = Double(bound.frames) * Double(plan.levels.count)
    var bytes = bound.bytes * Int64(plan.levels.count)
    var session = plan.lowered
    var made: [URL] = []
    var order: [ClipID] = []
    var files: [ClipID: FileID] = [:]
    var done = 0.0
    var reported = 0.0
    do throws(ClipRenderError) {
        for level in plan.levels {
            for entry in level {
                let (base, frames) = (done, Double(try runSize(entry.clips, in: session).frames))
                let outcome = try renderClips(
                    [(entry.clips, entry.request.treatment)], of: session, in: package, bytes: bytes,
                    freeBytes: freeBytes, component: component, readFault: readFault, isDownloaded: isDownloaded,
                    progress: { fraction in
                        let value = (base + fraction * frames) / total
                        guard value > reported, value < 1 else { return }
                        reported = value
                        progress(value)
                    }, isCancelled: isCancelled)
                bytes = 0
                done += frames
                session = outcome.session
                made += outcome.made
                for clip in outcome.clips where files.updateValue(clip.file, forKey: clip.clip) == nil {
                    order.append(clip.clip)
                }
            }
        }
    } catch {
        removeMadeFiles(made)
        throw error
    }
    progress(1)
    return ClipRenderOutcome(
        session: session, made: made, clips: order.map { RenderedClip(clip: $0, file: files[$0]!) },
        unchanged: plan.unchanged)
}

/// The frames and the WAV bytes of the runs of `clips` in `session`.
private func runSize(_ clips: [ClipID], in session: Session) throws(ClipRenderError) -> (frames: Int64, bytes: Int64) {
    let runs: [ClipRun]
    do throws(SessionError) { runs = try session.clipRuns(of: clips) } catch { throw .session(error) }
    var size = (frames: Int64(0), bytes: Int64(0))
    for run in runs {
        let frames = Int64((run.span.upperBound - run.span.lowerBound).count)
        // `clipRuns` refuses a clip whose file is not in the pool.
        let channels = session.files[run.file]!.layout.channelCount
        size = (size.frames + frames, size.bytes + wavFileBytes(frames: frames, channels: channels))
    }
    return size
}

/// The one entry of a render request (decision 0057): `clipRenderPlan` on `session`, the role
/// check of each clip of `clips`, also of an unchanged clip, then `renderLevels`. A request that
/// needs no render gives `session`, no file, and `unchanged`.
/// `Studio.renderClips` and `ClipRenderWork` call it. It blocks: never call it on the main actor.
package func renderRequest(
    _ clips: [ClipID], request: ClipRenderRequest, of session: Session, in package: URL,
    freeBytes: () -> Int64, component: (Int) -> AudioComponentDescription = { _ in .soundIsolation },
    readFault: ReadFault? = nil, isDownloaded: (URL) -> Bool = sourceIsDownloaded,
    progress: @escaping (Double) -> Void = { _ in }, isCancelled: @escaping () -> Bool = { false }
) throws(ClipRenderError) -> ClipRenderOutcome {
    let plan: ClipRenderPlan
    do throws(SessionError) { plan = try clipRenderPlan(clips, request: request, in: session) } catch {
        throw .session(error)
    }
    try request.treatment.checkRoles(of: clips, in: session)
    return try renderLevels(
        plan, in: package, freeBytes: freeBytes, component: component, readFault: readFault,
        isDownloaded: isDownloaded, progress: progress, isCancelled: isCancelled)
}
