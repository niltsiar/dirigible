import DirigibleTimeline
import Foundation

/// Low record time (decision 0023): before a take under 3 h, during a take under 10 min. A
/// banner that shows hides only over the limit plus a band (300 s before a take, 60 s during it),
/// so it does not blink at the limit.
func showsLowRecordTime(left: Duration, recording: Bool, shownBefore: Bool) -> Bool {
    let (limit, band): (Duration, Duration) =
        recording ? (.seconds(600), .seconds(60)) : (.seconds(10_800), .seconds(300))
    return left < (shownBefore ? limit + band : limit)
}

/// The minutes of the banner "Less than N": the whole minutes left plus one, so the text is true
/// also at a whole minute and in the last minute (1 min, not 0 min).
func lowRecordTimeMinutes(_ left: Duration) -> Int { Int(left / .seconds(60)) + 1 }

/// The units of the record time in the subtitle and the banner: "2 hr, 10 min". The style rounds
/// to the nearest minute, so each caller gives it whole minutes.
func recordTimeStyle(_ locale: Locale) -> Duration.UnitsFormatStyle {
    Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .abbreviated).locale(locale)
}

/// The text of the low-record-time banner: "Less than 2 hr, 1 min of record time left on this
/// disk. ...". `text` gives the value of a key.
func lowRecordTimeText(minutes: Int, locale: Locale = .current, text: (L10n) -> String = { $0.text }) -> String {
    String(
        format: text(.bannerLowRecordTimeLeft), locale: locale,
        Duration.seconds(minutes * 60).formatted(recordTimeStyle(locale)))
}

/// The window subtitle: the rate and at most one more part, so it has one middle dot at most. The
/// part is "Pre-roll" during the pre-roll of a take, else "Archived" or "Partly archived, 28 of 40
/// files are FLAC", else the record time left ("2 hr, 10 min left", rounded down to the minute), else
/// the drag mode when it is not Overwrite ("Shuffle drag mode"). No plural form (0010); Foundation
/// gives the units of the time. `text` gives the value of a key.
func subtitleText(
    rate: Int, recordTimeLeft: Duration?, preRoll: Bool = false, dragMode: DragMode = .overwrite,
    archive: ArchiveCounts? = nil, locale: Locale = .current,
    text: (L10n) -> String = { $0.text }
) -> String {
    let kHz = kiloHertzText(rate, locale: locale)
    let part: String? =
        if preRoll {
            text(.subtitlePreRoll)
        } else if let archive {
            archive.flac == archive.total
                ? text(.subtitleArchived)
                : String(format: text(.subtitleArchivedPart), locale: locale, archive.flac, archive.total)
        } else if let recordTimeLeft {
            String(
                format: text(.subtitleRecordTime), locale: locale,
                Duration.seconds(Int(recordTimeLeft / .seconds(60)) * 60).formatted(recordTimeStyle(locale)))
        } else if dragMode != .overwrite {
            String(format: text(.timelineDragModeCue), locale: locale, text(dragMode.title))
        } else {
            nil
        }
    return ["\(kHz) kHz", part].compactMap { $0 }.joined(separator: " · ")
}
