import DirigibleCore
import Foundation

private let clips = Param.required("clips", "The clip IDs: one or more.", .strings(minItems: 1))
private let clear = Param.defaulted(
    "clear", "Remove the ride in place of making it. It reads no audio.", .boolean, false)
private let from = Param<Int?>.optional(
    "from", "With clear: the first timeline frame of the range to remove. Give it with to.", .integer())
private let to = Param<Int?>.optional(
    "to", "With clear: the timeline frame after the range to remove. Give it with from.", .integer())

/// `clip_level_over_time` (decision 0064). It has its own file because `MCPClipTools.swift` is at
/// its size limit.
let rideTools = [
    Tool(
        "clip_level_over_time",
        "Even out the level inside clips over time, as dirigible clip level-over-time. Use it for a speech clip "
            + "whose level moves inside it. It measures the clips and writes a second gain layer, the ride, of -6 to "
            + "+6 dB that follows the loudness of the speech; a pause keeps the gain of the last speech. The "
            + "ride adds to the gain points of the clip and changes no audio file. clip_envelope edits the points "
            + "and leaves the ride as it is. Give one line for each clip: \"<clip>: leveled, <lowest> to <highest> "
            + "dB, <n> points\", or \"<clip>: no measurement\" for a clip with no loudness to measure. With clear, "
            + "the ride goes: \"<clip>: ride removed\" or \"<clip>: no ride\"; with from and to, it goes only "
            + "inside that range, with a 500 ms ramp at each edge, and no other clip changes what it plays."
            + editCancelNote("no ride changes"),
        [clips, clear, from, to], batch: .alone
    ) { a throws(ToolError) in
        switch RideWork.parse(clips: try a[clips], clear: try a[clear], from: try a[from], to: try a[to]) {
        case .success(let work): return .ride(work)
        case .failure(let error): throw error
        }
    }
]
