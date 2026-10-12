import DirigibleCore
import Foundation

/// A ripple edit cuts or moves the timeline on the tracks of `track`, or on all tracks when it is
/// empty (decision 0037). A split take refuses each ripple tool.
private let scope = Param.defaulted(
    "track", "The tracks. Give none for all tracks, or one or more.", .strings(), [String]())
private let at = Param.required("at", "The timeline frame of the insert.", .integer())
private let length = Param.required("length", "The frames of silence to insert.", .integer(minimum: 0))
private let clip = Param.required("clip", "The clip ID.", .string)
private let edge = Param.required("edge", "start or end.", .choice(["start", "end"], EditRules.edge))
private let by = Param.required(
    "by", "The frames to move the edge; negative moves left. At the start edge, positive removes audio.", .integer())

let rippleTools = [
    Tool(
        "clip_ripple_delete",
        "Remove the frames in a range and move the later clips and the markers left to close the gap. A marker in "
            + "the range goes to its start.",
        [Arg.from, Arg.to, scope]
    ) { a throws(ToolError) in
        guard let range = EditRules.positiveRange(from: try a[Arg.from], to: try a[Arg.to]) else {
            throw ToolError("from must be less than to.")
        }
        let ids = try a[scope]
        return .edit(ripple: true) { session throws(SessionError) in
            try session.rippleDelete(range, on: EditRules.tracks(ids, of: session))
            return []
        }
    },
    Tool(
        "clip_ripple_insert",
        "Insert silence: split the clips at a frame, and move the later clips and the markers right.",
        [at, length, scope]
    ) { a throws(ToolError) in
        let (frame, frames, ids) = (Frames(try a[at]), Frames(try a[length]), try a[scope])
        return .edit(ripple: true) { session throws(SessionError) in
            try session.rippleInsert(frames, at: frame, on: EditRules.tracks(ids, of: session))
            return []
        }
    },
    Tool(
        "clip_ripple_trim",
        "Move one edge of a clip and ripple the span on the tracks: the later clips and the markers move with the "
            + "edge. The clip start stays. The track of the clip always ripples.",
        [clip, edge, by, scope]
    ) { a throws(ToolError) in
        let (id, side, frames, ids) = (ClipID(try a[clip]), try a[edge], Frames(try a[by]), try a[scope])
        return .edit(ripple: true) { session throws(SessionError) in
            try session.rippleTrim(id, edge: side, by: frames, on: EditRules.tracks(ids, of: session))
            return []
        }
    },
]
