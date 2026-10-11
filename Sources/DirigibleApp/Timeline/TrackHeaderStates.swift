import DirigibleAudio
import SwiftUI

/// The level of a live track on the meter scale: -60 dBFS to 0 dBFS as 0 to 1.
func meterLevel(_ live: LiveTrack) -> Double {
    live.peak > 0 ? max(0, min(1, (20 * log10(Double(live.peak)) + 60) / 60)) : 0
}

/// The meter and the state of a one-line row: a meter of 16 pt, and a symbol for a fault (red) or
/// dropped frames (orange), with the state text for VoiceOver and as its tooltip.
struct CompactLiveState: View {
    let live: LiveTrack
    /// The route label: the app of a `.waitingForApp` or `.noSound` track.
    let source: String
    let showsLoudness: Bool

    var body: some View {
        ProgressView(value: meterLevel(live)).frame(width: 16)
        if showsLoudness, let loudness = LoudnessText.header(live) { loudnessText(loudness) }
        if let fault {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .accessibilityLabel(Text(fault)).help(Text(fault))
        } else if live.droppedFrames > 0 {
            let text = L10n.trackDropped.format(live.droppedFrames)
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityLabel(Text(verbatim: text)).help(Text(verbatim: text))
        }
    }

    private var fault: String? {
        switch live.state {
        case .recording, .monitoring: nil
        case .deviceLost: L10n.trackStateDeviceLost.text
        case .writeFailed: L10n.trackStateWriteFailed.text
        case .retryStopped: L10n.trackStateRetryStopped.text
        case .waitingForApp: L10n.trackStateWaitingForApp.format(source)
        case .noSound: L10n.trackStateNoSound.format(source)
        }
    }
}

/// The meter and the state of an armed track during a take or a monitor.
struct LiveState: View {
    let live: LiveTrack
    /// The route label: the app of a `.waitingForApp` or `.noSound` track.
    let source: String
    /// False in a row of 80 pt or more: line 3 shows the no-sound state (`TrackRow.stateLine`).
    let showsNoSound: Bool
    /// Opens Privacy & Security > System Audio Recording (A9).
    let openSettings: () -> Void

    var body: some View {
        ProgressView(value: meterLevel(live)).frame(width: 60)
        if let loudness = LoudnessText.header(live) { loudnessText(loudness) }
        switch live.state {
        case .recording, .monitoring: EmptyView()
        case .deviceLost: Text(L10n.trackStateDeviceLost.key).foregroundStyle(.red)
        case .writeFailed: Text(L10n.trackStateWriteFailed.key).foregroundStyle(.red)
        case .retryStopped: Text(L10n.trackStateRetryStopped.key).foregroundStyle(.red)
        case .waitingForApp: Text(verbatim: L10n.trackStateWaitingForApp.format(source)).foregroundStyle(.secondary)
        case .noSound where showsNoSound:
            // A row of 56 to 79 pt has no room for the text and the "Privacy…" button.
            let full = HeaderStateText.noSound(source).full
            Button(action: openSettings) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .help(Text(verbatim: full))
            .accessibilityLabel(Text(verbatim: full))
        case .noSound: EmptyView()
        }
        if live.droppedFrames > 0 {
            Text(verbatim: L10n.trackDropped.format(live.droppedFrames)).foregroundStyle(.orange)
        }
    }
}

/// The short-term loudness of a track that records or monitors, in whole LU (decision 0033).
func loudnessText(_ text: String) -> some View {
    Text(verbatim: text).monospacedDigit().foregroundStyle(.secondary).help(Text(L10n.loudnessShortTip.key))
}
