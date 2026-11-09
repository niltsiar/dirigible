import AVFoundation
import DirigibleCore

/// The new ride lists of one Level Over Time read (run 2026-10-14-leveler).
package struct RideRead: Sendable {
    /// The new list of each written clip: `.empty` for a clip of a group with no reference.
    package let rides: [ClipID: GainEnvelope]
    /// The written clips of the groups with a reference, then of the groups with none.
    package let leveled: [ClipID]
    package let unmeasured: [ClipID]
}

/// Why a ride read stopped. It changes nothing.
package enum RideReadError: Error, Equatable {
    case cancelled
    /// A source file is missing, short, or unreadable (also a NaN or an infinity in it).
    case fault(FileID, MediaFault)
    /// The process had no free descriptor: the errno.
    case descriptor(Int32)
}

/// The ride list of each group of `groups`: one read of the group frames with a `LoudnessMeter`
/// that keeps its steps, the envelope gain at each step centre, `rideLayer`, then `decimated` at
/// 0.1 dB. The list of a group goes on its `written` clips. The read reads no ride layer, so a
/// second ride with no change between gives equal lists. `progress` gets the frames done over the
/// frames of all groups. It reads the disk, so never call it on the main actor.
package func rideLists(
    _ groups: [RideGroup], in session: Session, package: URL, progress: (Double) -> Void,
    isCancelled: () -> Bool
) throws(RideReadError) -> RideRead {
    if isCancelled() { throw .cancelled }
    progress(0)
    let total = Double(max(1, groups.reduce(0) { $0 + $1.frames.upperBound.count - $1.frames.lowerBound.count }))
    var done = 0
    var rides: [ClipID: GainEnvelope] = [:]
    var (leveled, unmeasured): ([ClipID], [ClipID]) = ([], [])
    for group in groups {
        let before = done
        let (steps, stepFrames) = try rideSteps(
            group, in: session, package: package, progress: { progress(Double(before + $0) / total) },
            isCancelled: isCancelled)
        done += group.frames.upperBound.count - group.frames.lowerBound.count
        let first = group.frames.lowerBound
        let envelope = steps.indices.map { group.envelopeGain(at: first + Frames((2 * $0 + 1) * stepFrames / 2)) }
        if let layer = rideLayer(stepMeanSquares: steps, envelopeDB: envelope) {
            let list = GainEnvelope.decimated(dB: layer, first: first, stepFrames: stepFrames, tolerance: 0.1)
            for clip in group.written { rides[clip] = list }
            leveled += group.written
        } else {
            for clip in group.written { rides[clip] = .empty }
            unmeasured += group.written
        }
        progress(Double(done) / total)
    }
    return RideRead(rides: rides, leveled: leveled, unmeasured: unmeasured)
}

/// The step mean squares of the frames of `group` and the frames of one step. No steps for a rate
/// that the meter refuses.
func rideSteps(
    _ group: RideGroup, in session: Session, package: URL, progress: (Int) -> Void, isCancelled: () -> Bool
) throws(RideReadError) -> (steps: [Double], stepFrames: Int) {
    let read: (meter: LoudnessMeter?, fault: MediaFault?)
    do throws(POSIXError) {
        read = try meterRead(
            group.file, frames: group.frames, in: session, package: package, keepsSteps: true, progress: progress,
            isCancelled: isCancelled
        ) { try $0.read(into: $1, frameCount: $2) }
    } catch {
        throw error.code == .ECANCELED ? .cancelled : .descriptor(error.code.rawValue)
    }
    if let fault = read.fault { throw .fault(group.file, fault) }
    guard let meter = read.meter else { return ([], 1) }
    return (meter.stepMeanSquares ?? [], meter.stepFrames)
}
