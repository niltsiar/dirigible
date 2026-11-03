import AVFoundation
import DirigibleCore

/// Starts the node of a play: at a host time in nanoseconds, or at once when nil. Tests record the
/// host time.
typealias NodeStart = @Sendable (AVAudioPlayerNode, UInt64?) -> Void

/// The take play of a pre-roll take (decision 0070, **One start path**): `apply` starts it at a
/// host time that keeps the lead.
extension Player {
    /// The take start of a play: the earliest start host time in nanoseconds, and the pre-roll
    /// span T - S.
    struct TakeStart: Sendable {
        let floor: UInt64
        let span: Frames
    }

    /// The start of a take feed: the host time in nanoseconds that frame `frame` plays at.
    struct TakeBase: Sendable {
        let host: UInt64
        let frame: Frames
    }

    /// The least time from a read of the host clock to the start host time that it picks.
    static let startMargin: UInt64 = 100_000_000
    /// The least time from the host time read before the start to the take start T.
    static let lead: UInt64 = 500_000_000

    /// Only the device clock follows the host time: manual rendering ignores it (probe U20).
    /// `AVAudioTime` takes host ticks, not nanoseconds.
    static func nodeStart(on output: Output) -> NodeStart {
        guard output == .device else { return { node, _ in node.play() } }
        return { node, host in node.play(at: host.map { AVAudioTime(hostTime: AudioConvertNanosToHostTime($0)) }) }
    }

    /// Starts the take feed of `take` at frame `frame`, after the first refill. The start host time
    /// is the latest of the floor, 100 ms after the host time read, and the lead of 0.5 s after it
    /// less the pre-roll span (P18). The paced pull owes its first frame at that host time.
    func startTake(_ take: TakeStart, node: AVAudioPlayerNode, from frame: Frames) -> TakeBase {
        let (host, instant) = (hostNanos(), now())
        let span = UInt64((Double(take.span.count) * 1e9 / Double(session.sampleRate)).rounded())
        let start = max(take.floor, host + Self.startMargin, host + Self.lead - min(span, Self.lead))
        startNode(node, start)
        pacedBase = instant + .nanoseconds(Int64(start) - Int64(host))
        return TakeBase(host: start, frame: frame)
    }
}
