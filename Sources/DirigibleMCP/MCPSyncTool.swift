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
        "Move a clip onto its audio on another track by the waveform, for a recording with no shared clock, "
            + "such as a guest file and the call track. It moves the whole clip by one lag and does not correct a "
            + "drift; the clips under its new place are cut, and no audio file changes. No match is an error and "
            + "changes nothing. The text is that of dirigible clip sync; dirigible help clip sync gives each line."
            + editCancelNote("no clip moves"),
        [clip, reference, within], batch: .alone
    ) { a throws(ToolError) in
        switch SyncWork.parse(clip: try a[clip], to: try a[reference], within: try a[within], front: .tool) {
        case .success(let work): return .sync(work)
        case .failure(let error): throw error
        }
    }
]
