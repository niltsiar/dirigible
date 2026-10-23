import Foundation

/// The level of one scan window of a stereo mix (decision 0062): the mean of the mean squares of
/// the two channels, and the largest absolute sample of both.
public struct WindowLevel: Hashable, Sendable {
    public let meanSquare: Float
    public let peak: Float

    public init(meanSquare: Float, peak: Float) {
        (self.meanSquare, self.peak) = (meanSquare, peak)
    }
}

/// The window levels of a range of a mix (decision 0062). Each window starts at a multiple of
/// `window` from session frame 0, so `range` starts on that grid; the last window ends at
/// `range.upperBound` and can be short.
public struct LevelSeries: Hashable, Sendable {
    public let range: Range<Frames>
    public let window: Frames
    /// One level for each window of `range`, in order.
    public let levels: [WindowLevel]

    /// Nil when `window` is under 1 frame, `range` does not start on the grid, or `levels.count`
    /// is not the window count of `range`.
    public init?(range: Range<Frames>, window: Frames, levels: [WindowLevel]) {
        let length = range.upperBound.count - range.lowerBound.count
        guard window.count >= 1, range.lowerBound.count % window.count == 0,
            levels.count == (length + window.count - 1) / window.count
        else { return nil }
        (self.range, self.window, self.levels) = (range, window, levels)
    }

    /// The frames of window `index`.
    func frames(of index: Int) -> Range<Frames> {
        let start = range.lowerBound.count + index * window.count
        return Frames(start)..<Frames(min(start + window.count, range.upperBound.count))
    }

    /// One step of `steps(of:)`: its frames, the mean square of its frames, and its peak.
    public struct Step: Hashable, Sendable {
        public let frames: Range<Frames>
        public let level: WindowLevel
    }

    /// The steps of `step` frames from the range start; the last step ends at the range end.
    /// Precondition: `step` is a positive multiple of `window`.
    public func steps(of step: Frames) -> [Step] {
        precondition(step.count > 0 && step.count % window.count == 0, "a step is a whole number of windows")
        let perStep = step.count / window.count
        return stride(from: 0, to: levels.count, by: perStep).map { first in
            let last = min(first + perStep, levels.count)
            var (sum, peak) = (0.0, Float(0))
            for index in first..<last {
                let frames = frames(of: index)
                sum += Double(levels[index].meanSquare) * Double(frames.upperBound.count - frames.lowerBound.count)
                peak = max(peak, levels[index].peak)
            }
            let frames = frames(of: first).lowerBound..<frames(of: last - 1).upperBound
            let length = Double(frames.upperBound.count - frames.lowerBound.count)
            return Step(frames: frames, level: WindowLevel(meanSquare: Float(sum / length), peak: peak))
        }
    }

    /// The mean square of `threshold` dBFS, as the duck compares it: 10^(dB / 10).
    package static func limit(_ threshold: Gain) -> Float { Float(pow(10, threshold.dB / 10)) }

    /// The runs of windows whose mean square passes `test`, in order. A run ends at the end of
    /// its last window.
    private func runs(where test: (Float) -> Bool) -> [Range<Frames>] {
        var runs: [Range<Frames>] = []
        var open: Frames?
        for (index, level) in levels.enumerated() {
            let frames = frames(of: index)
            if test(level.meanSquare) {
                if open == nil { open = frames.lowerBound }
            } else if let start = open {
                runs.append(start..<frames.lowerBound)
                open = nil
            }
        }
        if let start = open { runs.append(start..<range.upperBound) }
        return runs
    }

    /// The runs of windows over `threshold` dBFS: the speech of a duck (decision 0060).
    public func runs(over threshold: Gain) -> [Range<Frames>] {
        let limit = Self.limit(threshold)
        return runs { $0 > limit }
    }

    /// The silences of `range` (decision 0062): each run of windows at or under `threshold` dBFS
    /// of `minLength` frames or more, with its whole extent in the series, that intersects
    /// `range`. The scan reads past each edge to the end of a run that crosses it, so the
    /// minimum applies to the uncut run.
    public func silences(threshold: Gain, minLength: Frames, in range: Range<Frames>) -> [Range<Frames>] {
        let limit = Self.limit(threshold)
        return runs { $0 <= limit }.filter {
            $0.upperBound.count - $0.lowerBound.count >= minLength.count && $0.overlaps(range)
        }
    }

    /// The pause nearest to `at` in `at - window ..< at + window`, cut to the series (decision 0062):
    /// the silence of `silences(threshold:minLength:in:)` with the least distance from `at` to its
    /// range (0 from its start frame to its end frame; a tie takes the earlier silence), cut at the
    /// middle frame of the silence. With no silence, the middle frame of the quietest window that
    /// meets that range (the earlier on a tie) and its level.
    /// Precondition: the series holds a frame of that range.
    public func nearestPause(at: Frames, window: Frames, threshold: Gain, minLength: Frames) -> Pause {
        let asked = max(at - window, range.lowerBound)..<min(at + window, range.upperBound)
        precondition(!asked.isEmpty, "the series holds a frame of the asked range")
        func distance(_ silence: Range<Frames>) -> Int {
            max(silence.lowerBound.count - at.count, at.count - silence.upperBound.count, 0)
        }
        let silences = silences(threshold: threshold, minLength: minLength, in: asked)
        if let nearest = silences.min(by: { distance($0) < distance($1) }) {
            return .pause(nearest, cut: Frames((nearest.lowerBound.count + nearest.upperBound.count) / 2))
        }
        let first = (asked.lowerBound.count - range.lowerBound.count) / self.window.count
        let last = (asked.upperBound.count - 1 - range.lowerBound.count) / self.window.count
        let quietest = (first...last).min { levels[$0].meanSquare < levels[$1].meanSquare }!
        let frames = frames(of: quietest)
        return .noPause(cut: Frames((frames.lowerBound.count + frames.upperBound.count) / 2), level: levels[quietest])
    }
}

/// The result of `LevelSeries.nearestPause`.
public enum Pause: Hashable, Sendable {
    /// A silence and its cut frame, the middle of the silence.
    case pause(Range<Frames>, cut: Frames)
    /// No silence in the range: the middle frame of the quietest window, and its level.
    case noPause(cut: Frames, level: WindowLevel)
}
