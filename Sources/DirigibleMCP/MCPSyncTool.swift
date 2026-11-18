import DirigibleCore
import Foundation

private let clip = Param.required("clip", "The clip ID to move.", .string)
private let reference = Param.required(
    "to", "The ID of the reference track: the track that holds the same audio.", .string)
private let within = Param<Int?>.optional(
    "within",
    "The search distance on each side of the clip in whole seconds, 1 or more. The default is 1800 s; a longer "
        + "search than the session allows is refused with the largest value for this clip.", .integer())

/// `clip_sync` (decision 0076). Its own file because `MCPClipTools.swift` is at its size limit.
let syncTools = [
    Tool(
        "clip_sync",
        "Move a clip onto its audio on another track, as dirigible clip sync. Use it to line up a recording "
            + "that has no shared clock with a track that holds the same audio, for example a guest recording and "
            + "the call track. It reads the clip and the reference track and finds the one move that matches "
            + "their waveforms; the clip keeps its ID, and the clips under its new place are cut. It changes no "
            + "audio file. Give \"moved <clip> by <+|-><seconds> s (<frames> frames), match <score>\", then \"the "
            + "lag changes by <ms> ms across the clip\" when the lag changes along the clip, or \"the drift was "
            + "not measured: only one part of the clip matched\", then \"cut <seconds> s at the head\" when the "
            + "new start is before frame 0. It moves the whole clip by one lag and does not correct a drift. "
            + "No match changes nothing and is an error." + editCancelNote("no clip moves"),
        [clip, reference, within], batch: .alone
    ) { a throws(ToolError) in
        switch SyncWork.parse(clip: try a[clip], to: try a[reference], within: try a[within]) {
        case .success(let work): return .sync(work)
        case .failure(let error): throw error
        }
    }
]
