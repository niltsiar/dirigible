import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import Foundation

/// Edit > Replace and Edit > Paste to Fill Selection (decision 0053): `paste(mode:)` into the
/// selected range, so the paste path of decision 0042 runs for another package too.
extension SessionWindow {
    /// The selected range when Replace and Paste to Fill Selection can run: a range with frames on a
    /// track, a clipboard, an idle studio, and no run of the window. Nil otherwise, so a clip set
    /// gives none.
    var rangePasteRange: Range<Frames>? {
        guard importJob == nil, app?.clipboard != nil, let studio = idleStudio else { return nil }
        return timeline.selection.replaceRange(in: studio.session)
    }

    /// Replace pastes over the range and ripples all tracks, so it beeps under a pending or split
    /// take, as Insert does. Paste to Fill Selection moves nothing.
    func runRangePaste(_ command: TimelineCommand, _ studio: Studio) {
        guard let range = rangePasteRange else { return }
        if command == .replace {
            guard studio.canRipple else { return beep() }
            paste(mode: .replace(range))
        } else {
            paste(mode: .fill(range))
        }
    }

    /// "Replaced 1.5 seconds": the length of the clipboard, with one decimal.
    static func replacedText(
        clipboard: Frames, rate: Int, table: (L10n) -> String = { $0.text }, locale: Locale = .current
    ) -> String {
        String(
            format: table(.replaceDone), locale: locale, SilenceReview.seconds(clipboard, rate: rate, locale: locale))
    }

    /// "Filled 3.0 seconds with 3 clips.": the length of the range and the new clips.
    static func filledText(
        range: Range<Frames>, rate: Int, clips: Int, table: (L10n) -> String = { $0.text },
        locale: Locale = .current
    ) -> String {
        let length = SilenceReview.seconds(range.upperBound - range.lowerBound, rate: rate, locale: locale)
        if clips == 1 { return String(format: table(.fillDoneOne), locale: locale, length) }
        return String(format: table(.fillDone), locale: locale, length, clips)
    }
}
