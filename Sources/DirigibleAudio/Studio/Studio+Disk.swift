import DirigibleCore
import Foundation

/// The disk rule of a take (decision 0004): the watch of the free space and the record time.
extension Studio {
    /// Each check interval: stops the take when the free space is less than the WAV bytes of
    /// the take plus 1 GB. Before the stop, it ends the exports of the other studios to the
    /// volume of the package and checks again. The reads run off the main actor.
    /// It also sets `recordTimeLeft` of the `channels` of the take for the window subtitle, and
    /// writes `disk threshold` once at each fall of the free space under a `diskThresholds` value.
    func watchDisk(channels: Int) -> Task<Void, Never> {
        let (lock, environment, writers) = (lock, environment, Array(writers.values))
        let rate = session.sampleRate
        return Task { [weak self] in
            // The thresholds that the free space of the last check was under.
            var under = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: environment.diskCheckInterval)
                var wav: Int64 = 0
                for writer in writers { wav += writer.wavBytes }
                let free = await freeBytes(of: lock, environment)
                // The stop cancels on the main actor, so a tick after it sets nothing.
                guard !Task.isCancelled else { return }
                let now = diskThresholds.count { free < $0 }
                for threshold in diskThresholds[min(under, now)..<now] {
                    environment.log.note(.disk, "threshold", ["below": .number(threshold), "free": .number(free)])
                }
                under = now
                self?.recordTimeLeft = DirigibleAudio.remainingRecordTime(
                    free: free, wav: wav, channels: channels, rate: rate)
                guard free < wav + diskMargin else { continue }
                // Capture comes first (decision 0019): the next check counts the space again.
                if await self?.endOtherExports(onVolumeOf: lock) == true { continue }
                environment.log.note(
                    .take, "stopped", ["cause": .text("diskLow"), "free": .number(free), "wav": .number(wav)])
                try? await self?.stop(.diskLow)
                return
            }
        }
    }

    /// The WAV bytes that the finalize of the pending take needs (3 for each 4 CAF bytes, decision
    /// 0013) and the free bytes of the volume now. Nil with no pending take.
    public func pendingSpace() async -> (needed: Int64, free: Int64)? {
        guard let take = pendingTake?.take else { return nil }
        return (await pendingWAVBytes(take: take, of: lock), await freeBytes(of: lock, environment))
    }

    /// The record time that the free space gives the armed tracks: 7 bytes for each sample and
    /// channel after 1 GB and the WAV bytes of a pending take (decision 0004). Nil when a track
    /// is not in the session or no track is armed. ponytail: the session rate for every track;
    /// a device at a higher rate uses its CAF bytes faster.
    public func remainingRecordTime(armed: [TrackID]) async -> Duration? {
        var channels = 0
        for id in armed {
            guard let track = session.track(id) else { return nil }
            channels += track.layout.channelCount
        }
        guard channels > 0 else { return nil }
        let free = await freeBytes(of: lock, environment)
        var pending: Int64 = 0
        if let take = pendingTake?.take { pending = await pendingWAVBytes(take: take, of: lock) }
        return DirigibleAudio.remainingRecordTime(
            free: free, wav: pending, channels: channels, rate: session.sampleRate)
    }
}

/// The free bytes whose fall under each value writes one `disk threshold` line, from the highest.
let diskThresholds: [Int64] = [5_000_000_000, 2_000_000_000]

/// The record time that `free` bytes give `channels` channels at `rate`: 7 bytes for each sample
/// and channel (a CAF and its WAV) after 1 GB and the WAV bytes `wav` (decision 0004). Never
/// below 0.
public func remainingRecordTime(free: Int64, wav: Int64, channels: Int, rate: Int) -> Duration {
    let perSecond = Int64(channels * rate * 7)
    guard perSecond > 0 else { return .zero }
    return .seconds(Double(max(0, free - diskMargin - wav)) / Double(perSecond))
}
