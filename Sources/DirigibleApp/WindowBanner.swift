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
        }
    }

    var kind: Kind {
        switch self {
        case .playbackStopped, .lowRecordTime, .useHeadphones, .monitorHeadphones: .warning
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
        }
    }

    /// VoiceOver reads a new banner at this priority. Nil: no announcement.
    var announcement: NSAccessibilityPriorityLevel? {
        switch self {
        case .playbackStopped, .lowRecordTime, .useHeadphones, .monitorHeadphones: .high
        case .missingMedia, .exportReport: .medium
        }
    }
}
