import DirigibleCore
import Foundation

/// The take tool of `dirigible mcp` (decision 0061). It shares its argument rules and its text
/// with `dirigible take map` through `TakeWork`.
private let frames = Param.required(
    "frames", "The take frames from the record start of the take, or timeline frames with timeline.",
    .integers(minItems: 1))
private let take = Param<Int?>.optional(
    "take", "The take number. Give it when the session has two takes with audio or more.", .integer(minimum: 1))
private let timeline = Param.defaulted(
    "timeline", "Give the take frame of each timeline frame in place of the timeline frames of each take frame.",
    .boolean, false)
private let tracks = Param<[String]?>.optional(
    "track", "Only these track IDs. The default is every track.", .strings(minItems: 1))

let takeTools = [
    Tool(
        "take_map",
        "Give the timeline frames of take frames, as dirigible take map. Take frame 0 is the record start of the "
            + "take. One line for each frame: the frame, then track:frame for each clip that plays it, or cut when "
            + "an edit removed it. With timeline, the frame, then track:take frame for each track, or none.",
        [frames, take, timeline, tracks], saves: false, batch: .alone
    ) { a throws(ToolError) in
        .takeMap(
            try TakeMapQuery(
                frames: try a[frames], take: try a[take], timeline: try a[timeline],
                tracks: (try a[tracks] ?? []).map { TrackID($0) }))
    }.hinted(.readOnly)
]
