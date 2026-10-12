import AVFoundation
import Foundation

/// The test helpers of the Player: offline pulls with and without the wait for the feed.
extension Player {
    /// Tests only: the chunks that the loudness meter keeps.
    var loudnessQueued: Int { loudness.queued }

    /// Tests only: pulls `frames` output frames from the offline engine, as two channel arrays.
    /// Before each pull it waits until the tick has scheduled the frames, as the device clock
    /// gives it time to, so the wait ends on the frames, and one budget of 30 s for the call is
    /// only a hang guard. The budget counts only the time that the wait is awake: in a full suite
    /// the wait (`Task.sleep`) can wait more than 30 s for a pool thread. On macOS 15 the tick
    /// needs no pool thread; on macOS 14 its task hop waits too. `starve` pulls with no wait and
    /// no suspension, so the queue runs no tick and the node can run dry, as a late refill on a
    /// slow disk does.
    func renderOffline(frames: Int, starve: Bool = false) async -> [[Float]] {
        var out: [[Float]] = [[], []]
        var left = frames
        var budget = Duration.seconds(30)
        while left > 0 {
            let count = min(left, chunk)
            if !starve { await waitForFeed(count, budget: &budget) }
            let pulled = pull(count)
            for channel in 0..<2 { out[channel] += pulled?[channel] ?? [Float](repeating: 0, count: count) }
            left -= count
        }
        return out
    }

    /// Tests only: pulls `frames` output frames from the offline engine, one chunk each 0.1 s, as
    /// the device clock does, with no wait for the feed. Each pull is a `queue.asyncAfter` block
    /// with `assumeIsolated`, so no pull needs a thread of the cooperative pool; a task resume
    /// onto the queue can wait for one (probe E5). `end` is the instant of the last pull.
    @available(macOS 15, *)
    nonisolated func renderPaced(frames: Int) async -> (out: [[Float]], end: ContinuousClock.Instant) {
        await withCheckedContinuation { done in pace(frames, out: [[], []], done: done) }
    }

    @available(macOS 15, *)
    private nonisolated func pace(
        _ left: Int, out: [[Float]], done: CheckedContinuation<(out: [[Float]], end: ContinuousClock.Instant), Never>
    ) {
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
            self.assumeIsolated { player in
                let count = min(left, player.chunk)
                let pulled = player.pull(count)
                var out = out
                for channel in 0..<2 { out[channel] += pulled?[channel] ?? [Float](repeating: 0, count: count) }
                if left > count {
                    player.pace(left - count, out: out, done: done)
                } else {
                    done.resume(returning: (out, .now))
                }
            }
        }
    }

    /// Each poll of 1 ms takes its time off `budget`, at most 10 ms. A later wake-up waited for a
    /// pool thread, not for the refill. The node position can be the start of the last pull, not
    /// its end, so the wait asks for one chunk more than the pull: with one chunk, a pull on a
    /// full suite ran before the refill and played silence.
    private func waitForFeed(_ count: Int, budget: inout Duration) async {
        while let feed, feed.scheduled - nodeFrames() < count + chunk, feed.scheduled < length(feed), budget > .zero {
            let start = ContinuousClock.now
            try? await Task.sleep(for: .milliseconds(1))
            budget -= min(ContinuousClock.now - start, .milliseconds(10))
        }
    }

    private func pull(_ count: Int) -> [[Float]]? {
        guard let engine = graph?.engine, engine.isRunning,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(count)),
            (try? engine.renderOffline(AVAudioFrameCount(count), to: buffer)) == .success
        else { return nil }
        return (0..<2).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: count)) }
    }

    /// Tests only: posts the configuration change of this engine, as the system does.
    func postConfigurationChange() {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: graph?.engine)
    }
}
