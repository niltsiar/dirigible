import DirigibleTimeline

/// The text that VoiceOver reads after a step of the waveform range: "Waveform range 72 dB". `text`
/// gives the value of a key.
func waveformAnnouncement(_ range: WaveformRange, text: (L10n) -> String = { $0.text }) -> String {
    String(format: text(.waveformZoomAnnounce), locale: .current, range.rawValue)
}

extension SessionWindow {
    /// View > Waveform Zoom In, Waveform Zoom Out, and Reset Waveform Zoom. A step sets the range of
    /// this window and says it. A step that cannot go (an end of the ranges, or Reset at the app
    /// default) beeps and says nothing. A lane gesture keeps the lane rows of its preview until the
    /// mouse-up, so a step waits for it, as the height keys do.
    func zoomWaveform(_ command: TimelineCommand) {
        guard timelineView?.gesture.isActive != true else { return }
        let range = timeline.waveformRange
        let target: WaveformRange? =
            switch command {
            case .waveformZoomIn: range.zoomedIn
            case .waveformZoomOut: range.zoomedOut
            default: app?.waveformRangeDefault == range ? nil : app?.waveformRangeDefault
            }
        guard let target else { return beep() }
        timeline.waveformRange = target
        chrome?.announce(waveformAnnouncement(target), .high)
    }
}
