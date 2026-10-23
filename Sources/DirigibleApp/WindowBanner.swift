import AppKit
import DirigibleAudio
import DirigibleCore

/// The loudness report of an export, the name of its file, and the session revision at its end.
struct ExportReportShown: Equatable {
    let report: LoudnessReport
    let file: String
    let revision: Int
}

/// The report of the last Auto Level, the session revision after it, and the number of its press,
/// so each press gives a new banner key and VoiceOver reads each result.
struct LevelReportShown: Equatable {
    let report: LevelReport
    let revision: Int
    let press: Int
}

/// The banner of the last duck that found no speech or did not read a speech file, and the
/// session revision after it.
struct DuckReportShown: Equatable {
    let banner: WindowBanner
    let revision: Int
}

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
    /// The count of cues that an exported transcript file leaves out because they have no length,
    /// as `dirigible transcript export` warns (decision 0061).
    case transcriptLeftOut(count: Int, file: String)
    /// The result of an Auto Level (run 2026-10-12-autolevel-fader). The press number makes a
    /// new key for each press. A warning when a clip is at the 20 dB limit.
    case levelReport(LevelReport, press: Int)
    /// The files that Remove Unused Files moved to the Trash: the count and the bytes (decision 0047).
    case unusedFilesMoved(count: Int, bytes: Int64)
    /// The files that Remove Unused Files did not move: they stay in `Clips/`.
    case unusedFilesFailed([String])
    /// An agent record request ended with no answer (decision 0048). Nil: the agent gave no name.
    case consentExpired(agent: String?)
    /// A duck found no speech over the threshold in dBFS, so it changed nothing (decision 0060),
    /// with the paths of the speech files that did not read. The press number of the duck makes a
    /// new key for each duck, so VoiceOver reads each result.
    case duckNoSpeech(threshold: Double, unread: [String], press: Int)
    /// A duck did not read the speech files of these paths, so the music stays up over them.
    case duckUnread([String], press: Int)
    /// A revision of `agent` moved part of the audio of `take`, so the take is out of sync with
    /// its recording from the timeline frame `from` at `rate` (decision 0061). Nil: the agent gave
    /// no name. `revision` is the session revision of the edit, which its Undo button undoes.
    case takeSyncBroken(take: Int, from: Frames, rate: Int, agent: String?, revision: Int)

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
        case .transcriptLeftOut: "transcriptLeftOut"
        case .levelReport(_, let press): "levelReport.\(press)"
        case .unusedFilesMoved: "unusedFilesMoved"
        case .unusedFilesFailed: "unusedFilesFailed"
        case .consentExpired: "consentExpired"
        case .duckNoSpeech(_, _, let press): "duckNoSpeech.\(press)"
        case .duckUnread(_, let press): "duckUnread.\(press)"
        case .takeSyncBroken(let take, _, _, _, _): "takeSyncBroken.\(take)"
        }
    }

    var kind: Kind {
        switch self {
        case .playbackStopped, .lowRecordTime, .useHeadphones, .monitorHeadphones, .chaptersDropped,
            .chapterImagesOmitted, .transcriptLeftOut, .duckNoSpeech, .duckUnread, .takeSyncBroken:
            .warning
        case .missingMedia, .unusedFilesFailed: .error
        case .unusedFilesMoved, .consentExpired: .info
        case .levelReport(let report, _): report.atLimit > 0 ? .warning : .info
        case .exportReport(let report, _): report.exceedsLevelLimit ? .warning : .info
        }
    }

    var text: String {
        switch self {
        case .playbackStopped(let stop): L10n.message(for: stop)
        case .missingMedia(let paths): L10n.mediaMissing.format(paths.joined(separator: ", "))
        case .lowRecordTime(let minutes): lowRecordTimeText(minutes: minutes)
        case .useHeadphones: L10n.bannerUseHeadphones.text
        case .monitorHeadphones: L10n.bannerMonitorHeadphones.text
        case .exportReport(let report, let file):
            L10n.bannerExportReport.format(file, L10n.message(for: report)) + L10n.largeGainHint(for: report)
        case .chaptersDropped(let names, let file):
            L10n.bannerExportChapterDropped.format(file, names.joined(separator: ", "))
        case .chapterImagesOmitted(let file): L10n.bannerExportChapterImagesOmitted.format(file)
        case .transcriptLeftOut(let count, let file): L10n.bannerTranscriptLeftOut.format(file, count)
        case .levelReport(let report, _): L10n.message(for: report)
        case .unusedFilesMoved(let count, let bytes): L10n.bannerUnusedMoved.format(count, L10n.bytes(bytes))
        case .unusedFilesFailed(let paths): L10n.bannerUnusedFailed.format(paths.joined(separator: ", "))
        case .consentExpired(let agent?): L10n.bannerConsentExpired.format(agent)
        case .consentExpired(nil): L10n.bannerConsentExpiredUnnamed.text
        case .duckNoSpeech(let threshold, let unread, _) where unread.isEmpty: L10n.errorDuckNoSpeech.format(threshold)
        case .duckNoSpeech(let threshold, let unread, let press):
            L10n.errorDuckNoSpeech.format(threshold) + " " + WindowBanner.duckUnread(unread, press: press).text
        case .duckUnread(let paths, _): L10n.bannerDuckUnread.format(paths.joined(separator: ", "))
        case .takeSyncBroken(let take, let from, let rate, let agent, _):
            takeSyncBreakText(take: take, from: from, rate: rate, agent: agent)
        }
    }

    /// VoiceOver reads a new banner at this priority. Nil: no announcement.
    var announcement: NSAccessibilityPriorityLevel? {
        switch self {
        case .playbackStopped, .lowRecordTime, .useHeadphones, .monitorHeadphones: .high
        case .missingMedia, .exportReport, .chaptersDropped, .chapterImagesOmitted, .transcriptLeftOut, .levelReport,
            .unusedFilesMoved,
            .unusedFilesFailed, .consentExpired, .duckNoSpeech, .duckUnread, .takeSyncBroken:
            .medium
        }
    }
}

/// The text of the take sync banner: "Claude Code moved part of the take audio. Take 4 is out of
/// sync with the recording from 0:21:07 on the timeline." `text` gives the value of a key.
func takeSyncBreakText(
    take: Int, from: Frames, rate: Int, agent: String?, text: (L10n) -> String = { $0.text }
) -> String {
    let time = takeSyncClock(from, rate: rate)
    guard let agent else { return String(format: text(.bannerTakeSyncBrokenUnnamed), take, time) }
    return String(format: text(.bannerTakeSyncBroken), agent, take, time)
}

/// A break time of the take sync texts: h:mm:ss, with the digits cut as in the time display.
func takeSyncClock(_ frames: Frames, rate: Int) -> String {
    let seconds = frames.count / rate
    return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
}
