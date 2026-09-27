import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The transport bar (decision 0016): Record, Stop, Play, the record time left during a take, a
/// stop of playback that the user did not ask for, the missing audio files, and the record-over
/// warning. It reads observed values only. Slice 4 of the ui-shell run removes it.
struct TransportBar: View {
    let model: SessionWindow
    let studio: Studio

    var body: some View {
        let _ = model.countBody()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Button(L10n.transportRecord.key) { Task { await model.record() } }.disabled(!model.canRecord)
                Button(L10n.transportStop.key) { Task { await model.stopOrPause() } }
                Button(L10n.transportPlay.key) { Task { await studio.perform(.playStop) } }.disabled(!model.canEdit)
                if let left = studio.recordTimeLeft {
                    Text(verbatim: L10n.transportRemaining.format(left.formatted(.time(pattern: .hourMinute))))
                }
                Spacer()
            }
            // Stored values that the chrome loop writes on a change: no body reads `Studio.play`.
            if let stop = model.shown.playbackStop {
                Text(verbatim: L10n.message(for: stop)).foregroundStyle(.orange)
            }
            if !studio.missingMedia.isEmpty {
                let paths = studio.missingMedia.keys.sorted().map { studio.session.files[$0]?.path ?? $0.rawValue }
                Text(verbatim: L10n.mediaMissing.format(paths.joined(separator: ", "))).foregroundStyle(.red)
            }
            // Only for a clip that the lanes do not show (decision 0017).
            if model.shown.recordOver {
                Text(L10n.transportRecordOver.key).foregroundStyle(.orange)
            }
        }
        .padding(8)
    }
}
