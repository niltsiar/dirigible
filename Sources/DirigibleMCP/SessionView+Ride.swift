import DirigibleCore
import Foundation

extension SessionView {
    /// The ride layer of a clip: the count of its points inside the clip window, and the
    /// lowest and highest ride gain in the window, in dB at 0.1 dB.
    struct RideView: Encodable, Equatable {
        let points: Int
        let lowest: Double
        let highest: Double

        /// The text of a summary: `ride <n> points <lowest> to <highest> dB`.
        var text: String {
            "ride \(points) \(points == 1 ? "point" : "points") \(String(format: "%.1f", lowest)) to "
                + "\(String(format: "%.1f", highest)) dB"
        }
    }

    /// `[frame, dB]`, the shape of a point of the tool `clip_envelope`.
    struct PointView: Encodable {
        let frame: Int
        let dB: Double

        func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(frame)
            try container.encode(dB)
        }
    }
}

extension Clip {
    /// The summary of the ride layer: nil with no ride point. The extremes cover the ride points
    /// inside the clip window and its gain at the first and the last frame of the window.
    var rideSummary: SessionView.RideView? {
        let gains = playedRideGains
        guard let lowest = gains.min(), let highest = gains.max() else { return nil }
        func tenth(_ dB: Double) -> Double { (dB * 10).rounded() / 10 + 0.0 }
        return SessionView.RideView(points: playedRidePoints.count, lowest: tenth(lowest), highest: tenth(highest))
    }

    /// The gain points inside the clip window, each at its timeline frame (decision 0060).
    var pointsInWindow: [(frame: Frames, gain: Gain)] {
        let window = offset..<(offset + length)
        return envelope.points.filter { window.contains($0.frame) }.map { ($0.frame - offset + start, $0.gain) }
    }

    /// The envelope gain at the first and the last frame of the clip window, at timeline frames
    /// `start` and `start + length - 1`, rounded to 0.01 dB. The `+ 0.0` turns a negative zero into 0.
    var windowEdges: (first: SessionView.PointView, last: SessionView.PointView) {
        func edge(_ frames: Frames) -> SessionView.PointView {
            let dB = envelope.gain(at: offset + frames)
            return SessionView.PointView(frame: (start + frames).count, dB: (dB * 100).rounded() / 100 + 0.0)
        }
        return (edge(.zero), edge(length - 1))
    }
}
