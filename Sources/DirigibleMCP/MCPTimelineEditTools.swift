import DirigibleCore
import Foundation

private let clip = Param.required("clip", "The left clip of the join.", .string)
private let clips = Param.required("clips", "The clip IDs: one or more.", .strings(minItems: 1))
private let rollBy = Param.required("by", "The frames to move the join; negative moves it left.", .integer())
private let slipBy = Param.required(
    "by", "The frames to move the audio; negative plays earlier audio of the file.", .integer())

private let shuffleClip = Param.required("clip", "The clip ID.", .string)
private let shuffleStart = Param.required(
    "start", "The timeline frame of the first clip frame, after the old place closes.", .integer())

/// `clip_close_gaps`, `clip_roll`, and `clip_slip` (decision 0036), and `clip_shuffle` (decision 0020), the
/// tools of `dirigible clip close-gaps`, `clip roll`, `clip slip`, and `clip shuffle`.
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
    Tool(
        "clip_shuffle",
        "Move a clip as a ripple: close its old place on its track, open room at the new start on the target "
            + "track, and put the clip there. The markers follow the ripple. No other track moves.",
        [shuffleClip, Arg.track, shuffleStart], batch: .step
    ) { a throws(ToolError) in
        let (id, track, frame) = (ClipID(try a[shuffleClip]), TrackID(try a[Arg.track]), Frames(try a[shuffleStart]))
        return .edit(ripple: true) { session throws(SessionError) in
            try session.shuffle(id, to: track, start: frame)
            return []
        }
    },
]
