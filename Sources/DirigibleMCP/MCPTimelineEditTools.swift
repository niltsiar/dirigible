import DirigibleCore
import Foundation

private let clip = Param.required("clip", "The left clip of the join.", .string)
private let clips = Param.required("clips", "The clip IDs: one or more.", .strings(minItems: 1))
private let rollBy = Param.required("by", "The frames to move the join; negative moves it left.", .integer())
private let slipBy = Param.required(
    "by", "The frames to move the audio; negative plays earlier audio of the file.", .integer())

/// `clip_close_gaps`, `clip_roll`, and `clip_slip` (decision 0036), the tools of `dirigible clip
/// close-gaps`, `clip roll`, and `clip slip`.
let timelineEditTools = [
    Tool(
        "clip_close_gaps",
        "On each track, move each clip after the first one to the end of the clip before it. No other clip and no "
            + "marker moves. Give the ID of each moved clip.",
        [clips], batch: .step
    ) { a throws(ToolError) in
        let ids = try a[clips].map { ClipID($0) }
        return .edit(ripple: false) { session throws(SessionError) in
            try session.closeGaps(ids).map(\.rawValue)
        }
    },
    Tool(
        "clip_roll",
        "Move the join between a clip and the clip that touches its end. The left clip grows by the frames and the "
            + "right clip loses them at its start.",
        [clip, rollBy], batch: .step
    ) { a throws(ToolError) in
        let (id, frames) = (ClipID(try a[clip]), Frames(try a[rollBy]))
        return .edit(ripple: false) { session throws(SessionError) in
            try session.roll(id, by: frames)
            return []
        }
    },
    Tool(
        "clip_slip",
        "Move the audio under clips and keep their place, length, and fades. All clips move, or none.",
        [clips, slipBy], batch: .step
    ) { a throws(ToolError) in
        let (ids, frames) = (try a[clips].map { ClipID($0) }, Frames(try a[slipBy]))
        return .edit(ripple: false) { session throws(SessionError) in
            try session.slip(ids, by: frames)
            return []
        }
    },
]
