import Foundation

/// The signed difference `to - from` in nanoseconds. Every host-time difference uses it, so a
/// first frame before the take start gives a negative value, not a trap.
package func nanos(from: UInt64, to: UInt64) -> Int64 { Int64(bitPattern: to &- from) }

extension Capture {
    /// The timeline frame of file frame 0 at `sampleRate`, the take anchor of decision 0004
    /// (**Timing**): the playhead, plus the host time from the take start to the first frame,
    /// minus the latency at the nominal device rate, each rounded at `sampleRate`. Nil when the
    /// sum is not an `Int`. Finalize and `TakeMap` both use it, so the two never differ.
    public func alignedStart(in recording: Recording, sampleRate: Int) -> Int? {
        let rate = Double(sampleRate)
        let latency = (Double(latency) * rate / nominalSampleRate).rounded()
        let hostOffset =
            (Double(nanos(from: recording.takeStartHostTimeNanos, to: hostTimeNanos)) * rate / 1e9).rounded()
        return Int(exactly: Double(recording.playheadFrame.count) + hostOffset - latency)
    }
}

/// The take time of the capture files of a session (decision 0061). The take time of a frame is its
/// time from the record start of its own take, at the session rate.
public struct TakeMap: Sendable {
    /// Where file frame 0 of a capture file is in the take time of `take`.
    public struct Origin: Hashable, Sendable {
        public let take: Int
        public let frame: Int
    }

    /// The origin of each file that has take time.
    public let origins: [FileID: Origin]

    /// `recordings` holds the take anchor of each capture. A file has an origin only when its
    /// capture ID equals its file ID, so a file that finalize did not make (an import, a paste
    /// from another package, a derived file) has none.
    public init(_ session: Session, recordings: [CaptureID: Recording]) {
        var origins: [FileID: Origin] = [:]
        for file in session.files.values {
            guard let id = file.capture, id.rawValue == file.id.rawValue, let capture = session.captures[id],
                let recording = recordings[id]
            else { continue }
            // The aligned start with the playhead at 0: the take time of file frame 0.
            var takeStart = recording
            takeStart.playheadFrame = .zero
            guard let frame = capture.alignedStart(in: takeStart, sampleRate: session.sampleRate) else { continue }
            origins[file.id] = Origin(take: recording.take, frame: frame)
        }
        self.origins = origins
    }
}
