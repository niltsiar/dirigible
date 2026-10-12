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
    /// The measured loudness and the gain of the returned session. A change under
    /// `levelTolerance` keeps the old gain, so this gain is then the old gain.
    case leveled(LUFS, Gain)
    /// No block passes the gates. The clip keeps its gain.
    case noMeasurement
    /// The file is missing or does not read. The clip keeps its gain.
    case unreadable
}

/// The counts of one Auto Level (decision 0031): the clips whose gain changed, the leveled clips
/// at the ±20 dB limit (changed or not), and the clips with no measurement or no readable file.
public struct LevelReport: Hashable, Sendable {
    public private(set) var changed = 0
    public private(set) var atLimit = 0
    public private(set) var unmeasured = 0

    /// Counts the `levels` of `autoLevel` against the gains of `before`.
    public init(_ levels: [ClipID: ClipLevel], before: Session) {
        for (clip, level) in levels {
            guard case .leveled(_, let gain) = level else {
                unmeasured += 1
                continue
            }
            if gain != before.clip(clip)?.clip.gain { changed += 1 }
            // The tolerance can keep an old gain a little under the clamp.
            if abs(gain.dB) >= Gain.levelLimit - levelTolerance { atLimit += 1 }
        }
    }

    /// True when no clip changed, none is at the limit, and each has a measurement: each clip is at
    /// the target level.
    public var isEmpty: Bool { changed == 0 && atLimit == 0 && unmeasured == 0 }

    init(changed: Int, atLimit: Int, unmeasured: Int) {
        (self.changed, self.atLimit, self.unmeasured) = (changed, atLimit, unmeasured)
    }
}

/// The target loudness of a track layout (decision 0008).
func clipTarget(_ layout: ChannelLayout) -> Double { LoudnessTarget.podcast.integrated(for: layout).value }

/// A new gain nearer than this to the old gain keeps the old gain, so a second level of the same
/// clips changes nothing.
let levelTolerance = 0.05

/// Gives each clip of `clips` the gain `clipTarget - measured`, clamped to ±20 dB (decisions
/// 0008 and 0031). A clip keeps its gain when the new gain differs by less than
/// `levelTolerance` dB. It ignores an ID that is not in `session`.
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

    var gains: [ClipID: Gain] = [:]
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
            // Nil only for a value that is not finite: the clamp keeps it in `Gain.range`.
            guard results[item.clip.id]?.integrated != nil,
                var gain = Gain(dB: min(max(base + delta, -Gain.levelLimit), Gain.levelLimit))
            else {
                levels[item.clip.id] = .noMeasurement
                continue
            }
            if abs(gain.dB - item.clip.gain.dB) < levelTolerance { gain = item.clip.gain }
            gains[item.clip.id] = gain
            levels[item.clip.id] = .leveled(integrated, gain)
        }
    }
    var leveled = session
    // Each clip is in `session`, so the edit cannot throw.
    try? leveled.setGains(gains)
    return (leveled, levels)
}
