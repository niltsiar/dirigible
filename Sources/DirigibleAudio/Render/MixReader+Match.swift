import Accelerate
import DirigibleCore
import Foundation

/// The voice match stage of a reader (decision 0074 D1, D2): the filter, the kernel cache, and
/// the scratch of one track pass. One owner, not Sendable: the queue of its reader. `update(_:)`
/// designs kernels; the render only reads them.
final class MatchStage {
    let filter: MatchFilter
    /// The longest output range of one pass.
    let span: Int
    /// The frames that a pass reads: the span plus the context on each side.
    let inputCount: Int
    /// The kernel of each heard track whose match is not bypassed, in the current session.
    private(set) var kernels: [TrackID: MatchFilter.Kernel] = [:]
    /// At most two designs for each track: the current session first, then the one before it.
    private var designs: [TrackID: [(gains: ThirdOctave.Gains, kernel: MatchFilter.Kernel)]] = [:]
    /// The gate ramp at a hard edge: 16 ms, one period of the 63 Hz band.
    let hardRamp: Int
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let filtered: UnsafeMutablePointer<Float>
    let gate: UnsafeMutablePointer<Float>

    init(sampleRate: Int, span: Int) {
        filter = MatchFilter(sampleRate: sampleRate)
        self.span = span
        inputCount = span + filter.taps - 1
        hardRamp = (sampleRate * 16 + 500) / 1_000
        left = .allocate(capacity: inputCount)
        right = .allocate(capacity: inputCount)
        filtered = .allocate(capacity: span)
        gate = .allocate(capacity: span)
    }

    deinit {
        left.deallocate()
        right.deallocate()
        filtered.deallocate()
        gate.deallocate()
    }

    /// Sets the kernels of `tracks`, each with a match that is not bypassed, and designs each one
    /// that the cache does not hold.
    func update(_ tracks: [Track]) {
        kernels.removeAll(keepingCapacity: true)
        for track in tracks {
            guard let match = track.match else { continue }
            let gains = match.gains(at: match.amount)
            var entries = designs[track.id] ?? []
            if let index = entries.firstIndex(where: { $0.gains == gains }) {
                entries.insert(entries.remove(at: index), at: 0)
            } else {
                entries.insert((gains, filter.kernel(gains)), at: 0)
                if entries.count > 2 { entries.removeLast() }
            }
            designs[track.id] = entries
            kernels[track.id] = entries[0].kernel
        }
    }

    /// Fills `gate` for the frames `start ..< start + count` from the clip extents of `clips` (in
    /// start order): 1 in an extent, and outside each edge a raised cosine from 1 at the edge to 0
    /// at the ramp length R from it. R is the longer of `hardRamp` and the fade of that edge, at most
    /// the context. Clips that touch or overlap make one extent; where two ramps meet, the larger
    /// value holds. False when the gate is 0 at each frame.
    func fillGate(_ clips: [SoundingClip], from start: Int, count: Int) -> Bool {
        gate.update(repeating: 0, count: count)
        var open = false
        var extent: (start: Int, end: Int, rampIn: Int, rampOut: Int)?
        for sounding in clips {
            let clip = sounding.clip
            let (first, end) = (clip.start.count, clip.end.count)
            let (rampIn, rampOut) = (ramp(clip.fades.fadeIn), ramp(clip.fades.fadeOut))
            if let current = extent, first <= current.end {
                if end >= current.end { extent = (current.start, end, current.rampIn, rampOut) }
            } else {
                if let current = extent { open = add(current, from: start, count: count) || open }
                extent = (first, end, rampIn, rampOut)
            }
        }
        if let extent { open = add(extent, from: start, count: count) || open }
        return open
    }

    private func ramp(_ fade: Frames) -> Int { min(max(hardRamp, fade.count), filter.contextFrames) }

    private func add(_ extent: (start: Int, end: Int, rampIn: Int, rampOut: Int), from start: Int, count: Int)
        -> Bool
    {
        let low = max(start, extent.start - extent.rampIn + 1)
        let high = min(start + count, extent.end + extent.rampOut - 1)
        guard low < high else { return false }
        for frame in low..<high {
            let (distance, length) =
                frame < extent.start
                ? (extent.start - frame, extent.rampIn)
                : frame >= extent.end ? (frame - extent.end + 1, extent.rampOut) : (0, 1)
            let value = distance == 0 ? 1 : Float(0.5 * (1 + cos(Double.pi * Double(distance) / Double(length))))
            gate[frame - start] = max(gate[frame - start], value)
        }
        return true
    }
}

extension MixReader {
    /// Adds `track` through its match to `out` over `range` (0074 D1, D2): for each piece of at most
    /// the span, the track over the piece plus the context on each side (zeros before frame 0) goes
    /// into the stage scratch, through the filter, and times the gate into the mix. A piece with no
    /// clip extent within its ramps reads nothing.
    func renderMatched(
        _ track: Track, through kernel: MatchFilter.Kernel, of stage: MatchStage, _ range: Range<Frames>,
        into out: UnsafePointer<UnsafeMutablePointer<Float>>
    ) {
        let context = stage.filter.contextFrames
        var start = range.lowerBound.count
        while start < range.upperBound.count {
            let end = min(start + stage.span, range.upperBound.count)
            let (count, input) = (end - start, end - start + 2 * context)
            let read = Frames(max(0, start - context))..<Frames(end + context)
            let clips = track.clips.sounding(in: read)
            if stage.fillGate(clips, from: start, count: count) {
                let skip = read.lowerBound.count - (start - context)
                stage.left.update(repeating: 0, count: input)
                stage.right.update(repeating: 0, count: input)
                add(track, clips, read, into: stage.left + skip, stage.right + skip)
                let target = start - range.lowerBound.count
                for channel in 0..<2 {
                    let scratch = channel == 0 ? stage.left : stage.right
                    stage.filter.filter(
                        UnsafeBufferPointer(start: scratch, count: input), through: kernel,
                        into: UnsafeMutableBufferPointer(start: stage.filtered, count: count))
                    let destination = out[channel] + target
                    vDSP_vma(stage.filtered, 1, stage.gate, 1, destination, 1, destination, 1, vDSP_Length(count))
                }
            }
            start = end
        }
    }
}
