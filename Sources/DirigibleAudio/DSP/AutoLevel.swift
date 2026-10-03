import DirigibleCore
import Foundation
import os

/// How `autoLevel` measures a set of clips.
public enum LevelMode: Sendable {
    /// Each clip gets the target alone.
    case eachClip
    /// The clips of one track get one delta, so the gain differences between them stay, unless a
    /// gain reaches the ±20 dB limit.
    case equallyPerTrack
}

/// The result of `autoLevel` for one clip.
public enum ClipLevel: Hashable, Sendable {
    /// The measured loudness and the new gain.
    case leveled(LUFS, Gain)
    /// No block passes the gates. The clip keeps its gain.
    case noMeasurement
    /// The file is missing or does not read. The clip keeps its gain.
    case unreadable
}

/// The target loudness of a track layout (decision 0008).
func clipTarget(_ layout: ChannelLayout) -> Double { LoudnessTarget.podcast.integrated(for: layout).value }

/// Gives each clip of `clips` the gain `clipTarget - measured`, clamped to ±20 dB (decisions
/// 0008 and 0031). It ignores an ID that is not in `session`.
/// - `.eachClip` measures each clip without its gain.
/// - `.equallyPerTrack` measures each clip with its gain, joins the blocks of the clips of one
///   track, and adds one delta to the gain of each measured clip of that track.
/// A clip with no measurement, a missing file, or a read fault keeps its gain. It never throws.
/// It reads the files of all clips in parallel and blocks until the end, so never call it on the
/// main actor or on a real-time thread.
public func autoLevel(_ clips: Set<ClipID>, _ mode: LevelMode, of session: Session, in package: URL)
    -> (session: Session, levels: [ClipID: ClipLevel])
{
    let found = session.tracks.flatMap { track in
        track.clips.filter { clips.contains($0.id) }.map { (clip: $0, track: track) }
    }
    // No entry: the file is missing or does not read. A short file measures the frames it has.
    let measured = OSAllocatedUnfairLock(initialState: [ClipID: Loudness]())
    DispatchQueue.concurrentPerform(iterations: found.count) { index in
        let clip = found[index].clip
        if let (value, fault) = try? clipLoudness(clip, in: session, package: package),
            fault != .missing, fault != .unreadable
        {
            let loudness = mode == .eachClip ? value : value.withGain(clip.gain)
            measured.withLock { $0[clip.id] = loudness }
        }
    }
    let results = measured.withLock { $0 }

    var leveled = session
    var levels: [ClipID: ClipLevel] = [:]
    let groups =
        mode == .eachClip ? found.map { [$0] } : Dictionary(grouping: found, by: \.track.id).values.map { $0 }
    for group in groups {
        let readable = group.filter { results[$0.clip.id] != nil }
        for item in group where results[item.clip.id] == nil { levels[item.clip.id] = .unreadable }
        let union = Loudness(union: readable.compactMap { results[$0.clip.id] })
        guard let integrated = union.integrated else {
            for item in readable { levels[item.clip.id] = .noMeasurement }
            continue
        }
        let delta = clipTarget(group[0].track.layout) - integrated.value
        for item in readable {
            let base = mode == .eachClip ? 0 : item.clip.gain.dB
            // Gain(dB:) is nil only for a value that is not finite.
            guard results[item.clip.id]?.integrated != nil,
                let gain = Gain(dB: min(max(base + delta, -Gain.levelLimit), Gain.levelLimit))
            else {
                levels[item.clip.id] = .noMeasurement
                continue
            }
            // The clip is in `session`, so the edit cannot throw.
            try? leveled.setGain(gain, clip: item.clip.id)
            levels[item.clip.id] = .leveled(integrated, gain)
        }
    }
    return (leveled, levels)
}
