import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The transport bar (decision 0016): Record, Stop, Play, the playhead time, the record time
/// left during a take, a stop of playback that the user did not ask for, the missing audio
/// files, and the record-over warning. It reads observed values only.
struct TransportBar: View {
    let model: SessionWindow
    let studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Button(L10n.transportRecord.key) { Task { await model.record() } }.disabled(!model.canRecord)
                Button(L10n.transportStop.key) {
                    Task { model.canStop ? await model.stop() : await studio.perform(.pause) }
                }
                Button(L10n.transportPlay.key) { Task { await studio.perform(.playStop) } }.disabled(!model.canEdit)
                Text(verbatim: timeText(studio.playhead, rate: studio.session.sampleRate)).monospacedDigit()
                if let left = studio.recordTimeLeft {
                    Text(verbatim: L10n.transportRemaining.format(left.formatted(.time(pattern: .hourMinute))))
                }
                Spacer()
            }
            if let stop = studio.playbackStop {
                Text(verbatim: L10n.message(for: stop)).foregroundStyle(.orange)
            }
            if !studio.missingMedia.isEmpty {
                let paths = studio.missingMedia.keys.sorted().map { studio.session.files[$0]?.path ?? $0.rawValue }
                Text(verbatim: L10n.mediaMissing.format(paths.joined(separator: ", "))).foregroundStyle(.red)
            }
            // Until run 4b draws the clips (plan gate 1 item 1).
            if model.canRecord, studio.session.hasClip(at: studio.playhead, on: Array(model.armed)) {
                Text(L10n.transportRecordOver.key).foregroundStyle(.orange)
            }
        }
        .padding(8)
    }
}

/// The playhead as h:mm:ss.mmm; the milliseconds are cut, not rounded.
func timeText(_ frames: Frames, rate: Int) -> String {
    let milliseconds = frames.count * 1000 / max(1, rate)
    let (hours, minutes) = (milliseconds / 3_600_000, milliseconds / 60_000 % 60)
    let (seconds, rest) = (milliseconds / 1000 % 60, milliseconds % 1000)
    return String(format: "%d:%02d:%02d.%03d", hours, minutes, seconds, rest)
}
