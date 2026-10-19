import DirigibleCore
import Foundation

extension Kind where T == [(frame: Frames, gain: Gain)] {
    /// Pairs of a timeline frame and a gain (V9 and decision 0060: `EditRules.envelopePoint`).
    static let points = Kind(
        schema: [
            "type": "array",
            "items": ["type": "array", "items": ["type": "number"] as Schema, "minItems": 2, "maxItems": 2] as Schema,
        ],
        expected: "an array of [frame, dB] pairs, each frame 0 or more and each gain \(Gain.rangeText)"
    ) { value in
        guard let pairs = value as? [Any] else { return nil }
        let points = pairs.compactMap { pair -> (frame: Frames, gain: Gain)? in
            guard let pair = pair as? [Any], pair.count == 2, let frame = Kind<Int>.integer().parse(pair[0]),
                let gain = Kind<Gain>.gain.parse(pair[1])
            else { return nil }
            return EditRules.envelopePoint(frame: frame, dB: gain.dB)
        }
        return points.count == pairs.count ? points : nil
    }
}

private let clip = Param.required("clip", "The clip ID.", .string)
private let points = Param.required(
    "points",
    "The gain points inside the clip window: [timeline frame, dB] pairs. They replace the points inside the window; "
        + "the points outside it stay. [] removes the points inside the window.", .points)
private let tracks = Param.required("track", "The tracks: one or more.", .strings(minItems: 1))
private let ramp = Param<Int?>.optional(
    "ramp", "The ramp length in frames, 1 or more. The default is 500 ms.", .integer(minimum: 1))

let envelopeTools = [
    Tool(
        "clip_envelope",
        "Set the gain points of a clip inside its window, in timeline frames. The points outside the window stay.",
        [clip, points]
    ) { a throws(ToolError) in
        let (id, given) = (ClipID(try a[clip]), try a[points])
        if let twice = EditRules.firstRepeat(given.map(\.frame)) { throw ToolError("Frame \(twice) is given twice.") }
        let map = Dictionary(uniqueKeysWithValues: given)
        return .edit(ripple: false) { session throws(SessionError) in
            try session.setEnvelope(map, clip: id)
            return []
        }
    },
    Tool(
        "clip_gain_range",
        "Add a gain to a range of tracks, with ramps outside the range, on top of the gain points. Give the ID of "
            + "each changed clip.",
        [tracks, Arg.from, Arg.to, Arg.gain, ramp]
    ) { a throws(ToolError) in
        let (targets, gain, frames) = (try a[tracks].map { TrackID($0) }, try a[Arg.gain], try a[ramp])
        guard let range = EditRules.gainRange(from: try a[Arg.from], to: try a[Arg.to]) else {
            throw ToolError("from must be less than to.")
        }
        return .edit(ripple: false) { session throws(SessionError) in
            try session.changeGain(
                by: gain, in: range, on: targets, ramp: frames.map { Frames($0) } ?? session.gainRamp
            ).map(\.rawValue)
        }
    },
]
