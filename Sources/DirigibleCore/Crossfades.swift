import Foundation

/// The crossfade length at each edge of a clip (decision 0036). Each length is even, in
/// `0...Frames.limit`; 0 is no crossfade. At a join, the end of the left clip equals the start of
/// the right clip, and `ClipLane` keeps that pairing.
public struct Crossfades: Hashable, Sendable {
    public let start: Frames
    public let end: Frames

    public static let zero = Crossfades(start: .zero, end: .zero)!

    /// Nil for an odd or negative length, or a length over `Frames.limit`.
    public init?(start: Frames, end: Frames) {
        guard start.isInRange, end.isInRange, start.count % 2 == 0, end.count % 2 == 0 else { return nil }
        self.init(valid: start, end: end)
    }

    /// Each length comes from a valid `Crossfades` or is 0.
    init(valid start: Frames, end: Frames) {
        self.start = start
        self.end = end
    }

    /// The crossfade of each edge of `clip` that `range` keeps; 0 at a new edge.
    static func kept(edgesOf clip: Clip, in range: Range<Frames>) -> Crossfades {
        Crossfades(
            valid: range.lowerBound == clip.start ? clip.crossfades.start : .zero,
            end: range.upperBound == clip.end ? clip.crossfades.end : .zero)
    }

    /// The crossfade of `edge`.
    public subscript(edge: Fades.Edge) -> Frames { edge == .start ? start : end }
}

/// The geometry of crossfades (decision 0036).
extension Clip {
    /// The clip as it sounds: the clip plus half of each crossfade from its media handles, with
    /// the crossfade of each edge as the fade of that edge. The render and the draw read it, so
    /// `Fades.gain` and `fadeEnvelope` play a crossfade with no neighbor lookup.
    public var sounding: Clip {
        guard crossfades != .zero else { return self }
        let (left, range) = (crossfades.start.half, soundingRange)
        let fades = Fades(
            fadeIn: crossfades.start == .zero ? self.fades.fadeIn : crossfades.start,
            fadeOut: crossfades.end == .zero ? self.fades.fadeOut : crossfades.end)!
        return Clip(
            id: id, file: file, start: range.lowerBound, offset: offset - left,
            length: range.upperBound - range.lowerBound, gain: gain, fades: fades, crossfades: .zero)
    }

    /// The timeline range of `sounding`.
    var soundingRange: Range<Frames> { (start - crossfades.start.half)..<(end + crossfades.end.half) }

    /// The frames of the clip that `edge` reaches: its fade plus half its crossfade. The fade
    /// handle sits at the reach.
    public func reach(_ edge: Fades.Edge) -> Frames { fades[edge] + crossfades[edge].half }

    /// The room of `edge`: the length minus the reach of the other edge.
    public func room(_ edge: Fades.Edge) -> Frames { length - reach(edge.other) }

    /// The room of a crossfade at `edge`: the length minus half the crossfade at the other edge.
    /// The fades yield to a crossfade, so they do not count.
    func crossfadeRoom(_ edge: Fades.Edge) -> Frames { length - crossfades[edge.other].half }

    /// The fades with the fade of `edge` at `value`, clamped to 0...room(edge): the other edge
    /// never yields (the fade handle and the inspector). Nil at an edge with a crossfade, or when
    /// the room is negative.
    public func fades(setting edge: Fades.Edge, to value: Frames) -> Fades? {
        guard crossfades[edge] == .zero else { return nil }
        let value = min(max(.zero, value), room(edge))
        return edge == .start
            ? Fades(fadeIn: value, fadeOut: fades.fadeOut) : Fades(fadeIn: fades.fadeIn, fadeOut: value)
    }

    /// `fades` fitted beside the crossfade halves: the fade of `edge` stays, and the other fade
    /// yields (decision 0035).
    public func fitting(_ fades: Fades, keeping edge: Fades.Edge) -> Fades {
        fades.fitted(to: max(.zero, crossfadeRoom(.end) - crossfades.end.half), keeping: edge)
    }

    /// True when `right` plays on from the frame of the file where this clip stops: the handles of
    /// a crossfade there hold one signal, which equal power makes 3 dB too loud.
    public func isSeamless(with right: Clip) -> Bool { file == right.file && offset + length == right.offset }
}

extension Frames {
    /// Half of an even crossfade length.
    var half: Frames { Frames(count / 2) }
}
