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
}
