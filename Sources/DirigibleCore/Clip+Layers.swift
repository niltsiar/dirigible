import Foundation

extension Clip {
    /// The gain in dB on top of `gain` at the file frame `frame`: the envelope plus the ride.
    public func layerGain(at frame: Frames) -> Double {
        envelope.gain(at: frame) + ride.gain(at: frame)
    }

    /// True when the envelope or the ride has a point.
    public var hasLayers: Bool { !envelope.isEmpty || !ride.isEmpty }

    /// The ride points inside the clip window. A ride list can be shared with clips that play
    /// other frames of the file, so only these points and the window edges are heard here.
    public var playedRidePoints: ArraySlice<GainEnvelope.Point> { ride.points(in: offset..<(offset + length)) }

    /// The ride gains in dB that the clip window plays: of `playedRidePoints` and at the first and
    /// the last frame of the window. Empty with no ride point.
    public var playedRideGains: [Double] {
        guard !ride.isEmpty else { return [] }
        return playedRidePoints.map(\.gain.dB) + [ride.gain(at: offset), ride.gain(at: offset + length - 1)]
    }
}

/// The file map of an edit that maps ride lists: the shift of each frame (0 for a rate change) and
/// the length of the new file.
struct FileMap: Equatable {
    let shift: Frames
    let length: Frames
}

/// The new list of each distinct pair of an old ride list and a file map in one edit (leveler
/// C34). Clips that share a list then share the new list, so the writer stores it once.
struct RideMaps {
    private var pairs: [(old: GainEnvelope, map: FileMap, new: GainEnvelope)] = []

    mutating func map(_ old: GainEnvelope, _ map: FileMap, _ transform: (GainEnvelope) -> GainEnvelope)
        -> GainEnvelope
    {
        guard !old.isEmpty else { return old }
        if let pair = pairs.last(where: { $0.map == map && $0.old == old }) { return pair.new }
        let new = transform(old)
        pairs.append((old, map, new))
        return new
    }

    mutating func moved(_ old: GainEnvelope, by shift: Frames, fileLength: Frames) -> GainEnvelope {
        map(old, FileMap(shift: shift, length: fileLength)) { $0.moved(by: shift, fileLength: fileLength) }
    }
}
