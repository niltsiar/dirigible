import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The level of a live track on the meter scale: -60 dBFS to 0 dBFS as 0 to 1.
func meterLevel(_ live: LiveTrack) -> Double {
    live.peak > 0 ? max(0, min(1, (20 * log10(Double(live.peak)) + 60) / 60)) : 0
}

/// The live state of `track` in a one-line row. It reads `liveTracks` in its own body, so a meter
/// report runs it and not the row (decision 0014).
struct CompactLiveState: View {
    let studio: Studio
    let track: TrackID
    let source: String
    let showsLoudness: Bool

    var body: some View {
        if let live = studio.liveTracks[track] {
            CompactLiveStateContent(live: live, source: source, showsLoudness: showsLoudness)
        }
    }
}

/// The meter and the state of a one-line row: a meter of 16 pt, and a symbol for a fault (red) or
/// dropped frames (orange), with the state text for VoiceOver and as its tooltip.
struct CompactLiveStateContent: View {
    let live: LiveTrack
    /// The route label: the app of a `.waitingForApp` or `.noSound` track.
    let source: String
    let showsLoudness: Bool

    var body: some View {
        ProgressView(value: meterLevel(live)).frame(width: 16).inputLevelAccessibility(live)
        if showsLoudness, let loudness = LoudnessText.header(live) { loudnessText(loudness) }
        if let fault {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                .accessibilityLabel(Text(fault)).help(Text(fault))
        } else if live.droppedFrames > 0 {
            let text = L10n.counted(live.droppedFrames, one: .trackDroppedOne, many: .trackDropped)
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
        case .noAccess: L10n.trackStateNoAccess.format(source)
        case .notStarted: L10n.trackStateNotStarted.text
        }
    }
}

/// The live state of `track` on line 2 of a row. It reads `liveTracks` in its own body, as
/// `CompactLiveState`.
struct LiveState: View {
    let studio: Studio
    let track: TrackID
    let source: String
    let showsNoSound: Bool
    let openSettings: () -> Void

    var body: some View {
        if let live = studio.liveTracks[track] {
            LiveStateContent(live: live, source: source, showsNoSound: showsNoSound, openSettings: openSettings)
        }
    }
}

/// The meter and the state of an armed track during a take or a monitor.
struct LiveStateContent: View {
    let live: LiveTrack
    /// The route label: the app of a `.waitingForApp` or `.noSound` track.
    let source: String
    /// False in a row of 80 pt or more: line 3 shows the no-sound state (`TrackRow.stateLine`).
    let showsNoSound: Bool
    /// Opens Privacy & Security > System Audio Recording (A9).
    let openSettings: () -> Void

    var body: some View {
        ProgressView(value: meterLevel(live)).frame(width: 60).inputLevelAccessibility(live)
        if let loudness = LoudnessText.header(live) { loudnessText(loudness) }
        switch live.state {
        case .recording, .monitoring: EmptyView()
        case .deviceLost: Text(verbatim: L10n.trackStateDeviceLost.text).foregroundStyle(.red)
        case .writeFailed: Text(verbatim: L10n.trackStateWriteFailed.text).foregroundStyle(.red)
        case .retryStopped: Text(verbatim: L10n.trackStateRetryStopped.text).foregroundStyle(.red)
        case .notStarted: Text(verbatim: L10n.trackStateNotStarted.text).foregroundStyle(.red)
        case .waitingForApp: Text(verbatim: L10n.trackStateWaitingForApp.format(source)).foregroundStyle(.secondary)
        case .noSound, .noAccess:
            // A row of 56 to 79 pt has no room for the text and the "Privacy…" button.
            if showsNoSound, let text = HeaderStateText.app(live.state, source) {
                Button(action: openSettings) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help(Text(verbatim: text.full))
                // VoiceOver: the label names the action; the value gives the state also with hints off.
                .accessibilityLabel(L10n.trackNoSoundSettings.key)
                .accessibilityValue(Text(verbatim: text.row))
                .accessibilityHint(Text(verbatim: text.full))
            }
        }
        if live.droppedFrames > 0 {
            Text(verbatim: L10n.counted(live.droppedFrames, one: .trackDroppedOne, many: .trackDropped))
                .foregroundStyle(.orange)
        }
    }
}

extension View {
    /// VoiceOver for a header meter: "Input level" and the level on the meter scale.
    func inputLevelAccessibility(_ live: LiveTrack) -> some View {
        accessibilityLabel(L10n.trackInputLevel.key)
            .accessibilityValue(Text(meterLevel(live), format: .percent.precision(.fractionLength(0))))
    }
}

/// The short-term loudness of a track that records or monitors, in whole LU (decision 0033).
func loudnessText(_ text: String) -> some View {
    Text(verbatim: text).monospacedDigit().foregroundStyle(.secondary).help(Text(L10n.loudnessShortTip.key))
}
