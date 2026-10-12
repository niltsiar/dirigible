import AppKit
import DirigibleAudio

/// A banner row of the window (decision 0023): a fact, then what to do.
enum WindowBanner: Equatable {
    case playbackStopped(PlaybackStop)
    case missingMedia([String])
    /// Whole minutes, so the row changes at most once a minute.
    case lowRecordTime(minutes: Int)
    /// The default output is the built-in speakers and an armed track records an app (F43).
    case useHeadphones
    /// The default output is the built-in speakers and Monitor Track is on (decision 0044).
    case monitorHeadphones
    /// The loudness of the last clean export with a target and the name of its file (decision
    /// 0032). A warning when the gain is over the auto-level limit.
    case exportReport(LoudnessReport, file: String)
    /// The names of the chapters that the exported file leaves out, because each starts at the
    /// time of another chapter, or at or after the end of the M4A audio (run
    /// 2026-10-11-chapters-in-file, C5f, code gate item D6).
    case chaptersDropped([String], file: String)
    /// The exported M4A has no chapter images: a chapter has no image, and the episode has no
    /// artwork (run 2026-10-11-chapters-in-file, C5b).
    case chapterImagesOmitted(file: String)

    enum Kind: CaseIterable {
        case warning, error, info, recording

        var symbol: String {
            switch self {
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            case .info: "info.circle"
            case .recording: "record.circle"
            }
        }

        /// The first word of the accessibility label of the row.
        var word: L10n {
            switch self {
            case .warning: .bannerKindWarning
            case .error: .bannerKindError
            case .info, .recording: .bannerKindInfo
            }
        }

        /// The accessibility label of a row: the kind word first, then the text.
        func label(_ text: String) -> String { "\(word.text): \(text)" }
    }

    /// The case with no value: a new banner of a kind that shows already is not new.
    var key: String {
        switch self {
        case .playbackStopped: "playbackStopped"
        case .missingMedia: "missingMedia"
        case .lowRecordTime: "lowRecordTime"
        case .useHeadphones: "useHeadphones"
        case .monitorHeadphones: "monitorHeadphones"
        case .exportReport: "exportReport"
        case .chaptersDropped: "chaptersDropped"
        case .chapterImagesOmitted: "chapterImagesOmitted"
        }
    }

    var kind: Kind {
        switch self {
        case .playbackStopped, .lowRecordTime, .useHeadphones, .monitorHeadphones, .chaptersDropped,
            .chapterImagesOmitted:
            .warning
        case .missingMedia: .error
        case .exportReport(let report, _): report.exceedsLevelLimit ? .warning : .info
        }
    }

    var text: String {
        switch self {
        case .playbackStopped(let stop): L10n.message(for: stop)
        case .missingMedia(let paths): L10n.mediaMissing.format(paths.joined(separator: ", "))
        case .lowRecordTime(let minutes): L10n.bannerLowRecordTime.format(minutes)
        case .useHeadphones: L10n.bannerUseHeadphones.text
        case .monitorHeadphones: L10n.bannerMonitorHeadphones.text
        case .exportReport(let report, let file):
            L10n.bannerExportReport.format(file, L10n.message(for: report)) + L10n.largeGainHint(for: report)
        case .chaptersDropped(let names, let file):
            L10n.bannerExportChapterDropped.format(file, names.joined(separator: ", "))
        case .chapterImagesOmitted(let file): L10n.bannerExportChapterImagesOmitted.format(file)
        }
    }

    /// VoiceOver reads a new banner at this priority. Nil: no announcement.
    var announcement: NSAccessibilityPriorityLevel? {
        switch self {
        case .playbackStopped, .lowRecordTime, .useHeadphones, .monitorHeadphones: .high
        case .missingMedia, .exportReport, .chaptersDropped, .chapterImagesOmitted: .medium
        }
    }
}
