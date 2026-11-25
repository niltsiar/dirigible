import AppKit
import DirigibleAudio
import DirigibleCore

/// The loudness report of an export, the name of its file, and the session revision at its end.
struct ExportReportShown: Equatable {
    let report: LoudnessReport
    let file: String
    let revision: Int
}

/// The report of the last Auto Level that has banner text, the session revision after it, and the number
/// of its press, so each press gives a new banner key and VoiceOver reads each result.
struct LevelReportShown: Equatable {
    let report: LevelReport
    let revision: Int
    let press: Int
}

/// A Reduce Noise run that changed no clip, the session revision after it, and the number of its run,
/// so each run gives a new banner key.
struct DenoiseReportShown: Equatable {
    let revision: Int
    let press: Int
}

/// The counts banner of the last Import Transcript, and the session revision after it.
struct TranscriptImportShown: Equatable {
    let text: String
    let revision: Int
    let press: Int
}

/// The banner of the last duck, Match Voice refusal, session import, or sync, and the session revision at
/// its end: the next change of the session hides it.
struct ToolBannerShown: Equatable {
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
    /// 0032). Shown only when the gain is over the auto-level limit: a warning.
    case exportReport(LoudnessReport, file: String)
    /// The older files of the prefix that a split export leaves in the folder, a warning, and the files
    /// of the set for its Show in Finder button (decision 0067). A set with no older file shows no banner.
    case exportSetDone(files: [URL], old: [String])
    /// A split export that stopped: the files on disk and the files of the set.
    case exportSetStopped(written: Int, count: Int)
    /// A split point that has no file of its own, because it starts at the time of the split point
    /// before it or at the end of the range (decision 0067).
    case exportSetDropped(Marker)
    /// The file names of the stems over 0 dBFS, where the file writer clips (decision 0078).
    case stemsClipped([String])
    /// The mix of the stems is over 0 dBFS, so the stems do not add up to a mix export.
    case stemsMixClipped
    /// A stem export that stopped: no stem was written.
    case stemsStopped
    /// The names of the chapters that the exported file leaves out, because each starts at the
    /// time of another chapter, or at or after the end of the M4A audio (run
    /// 2026-10-11-chapters-in-file, C5f, code gate item D6).
    case chaptersDropped([String], file: String)
    /// The exported M4A has no chapter images: a chapter has no image, and the episode has no
    /// artwork (run 2026-10-11-chapters-in-file, C5b).
    case chapterImagesOmitted(file: String)
    /// The exported MP3 or M4A has no title tag, because the episode has no title.
    case titleMissing(file: String)
    /// The count of cues that an exported transcript file leaves out because they have no length,
    /// as `dirigible transcript export` warns (decision 0061).
    case transcriptLeftOut(count: Int, file: String)
    /// What an Auto Level asks the user to check, or that no clip changed (run 2026-10-12-autolevel-fader).
    /// The press number makes a new key for each press. A warning when a clip is at the 20 dB limit
    /// or has no level.
    case levelReport(LevelReport, press: Int)
    /// A Reduce Noise run that changed no clip (decision 0054). The press number makes a new key for
    /// each run.
    case noiseUnchanged(press: Int)
    /// What a Repair Sound run asks the user to check (decision 0064): the level drop of a de-clip, or
    /// that it found no clipped peak. The press number makes a new key for each run.
    case soundRepaired(RepairResult, press: Int)
    /// The clips that a Level Over Time run could not measure, as a warning. The press number makes a
    /// new key for each run.
    case leveledOverTime(RideResult, press: Int)
    /// The refusal text of a Match Voice run that stored nothing. The press number makes a new key for
    /// each run.
    case voiceMatchRefused(String, press: Int)
    /// What the last Import Transcript skipped or dropped. The press number makes a new key.
    case transcriptImported(String, press: Int)
    /// The files that Remove Unused Files did not move: they stay in `Clips/`.
    case unusedFilesFailed([String])
    /// The session is archived as FLAC, with the Unarchive button (decision 0072).
    case archived
    /// The net bytes that an archive freed: the freed bytes less the FLAC bytes.
    case archiveSaved(net: Int64)
    /// The pool files that a package job kept as damaged.
    case archiveDamaged([String])
    /// An agent record request ended with no answer (decision 0048). Nil: the agent gave no name.
    case consentExpired(agent: String?)
    /// A duck found no speech over the threshold in dBFS, so it changed nothing (decision 0060),
    /// with the paths of the speech files that did not read. The press number of the duck makes a
    /// new key for each duck, so VoiceOver reads each result.
    case duckNoSpeech(threshold: Double, unread: [String], press: Int)
    /// A duck did not read the speech files of these paths, so the music stays up over them.
    case duckUnread([String], press: Int)
    /// A Sync Clip to Track found its match (decision 0076). `revision` is the session revision of the
    /// move, which its Undo button undoes, or nil when the clip was already in place: then the banner
    /// has no Undo. The press number makes a new key for each sync.
    case syncMoved(SyncMoved, revision: Int?, press: Int)
    /// A sync of `clip` found no match on `track`, so it changed nothing. The button opens the sheet
    /// again for `clip`, on another track when one exists, with the Correct drift box `correctsDrift`.
    case syncNoMatch(clip: ClipID, track: TrackID, clipName: String, trackName: String, correctsDrift: Bool, press: Int)
    /// A revision of `agent` moved part of the audio of `take`, so the take is out of sync with
    /// its recording from the timeline frame `from` at `rate` (decision 0061). Nil: the agent gave
    /// no name. `revision` is the session revision of the edit, which its Undo button undoes.
    case takeSyncBroken(take: Int, from: Frames, rate: Int, agent: String?, revision: Int)
    /// A take started during a transcription job (decision 0065, UI council C-7). Its button runs
    /// the same job again. The press number makes a new key for each stop.
    case transcriptionStopped(TranscribeRequest, press: Int)
    /// A transcription job kept no word, so the track is unchanged.
    case noWordsFound(press: Int)
    /// The result line of File > Import Session (decision 0075, C16) when it tells of a muted call track or a
    /// marker that was left out. The window posts the same text itself.
    case sessionImported(String, press: Int)

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

    /// The case with no value: a new banner of a kind that shows already is not new. A banner that a set
    /// can show for several files adds the file name, so each key is unique in one window.
    var key: String {
        switch self {
        case .playbackStopped: "playbackStopped"
        case .missingMedia: "missingMedia"
        case .lowRecordTime: "lowRecordTime"
        case .useHeadphones: "useHeadphones"
        case .monitorHeadphones: "monitorHeadphones"
        case .exportReport(_, let file): "exportReport.\(file)"
        case .exportSetDone: "exportSetDone"
        case .exportSetStopped: "exportSetStopped"
        case .exportSetDropped(let marker): "exportSetDropped.\(marker.id)"
        case .stemsClipped: "stemsClipped"
        case .stemsMixClipped: "stemsMixClipped"
        case .stemsStopped: "stemsStopped"
        case .chaptersDropped(_, let file): "chaptersDropped.\(file)"
        case .chapterImagesOmitted(let file): "chapterImagesOmitted.\(file)"
        case .titleMissing(let file): "titleMissing.\(file)"
        case .transcriptLeftOut: "transcriptLeftOut"
        case .levelReport(_, let press): "levelReport.\(press)"
        case .noiseUnchanged(let press): "denoiseReport.\(press)"
        case .soundRepaired(_, let press): "repairReport.\(press)"
        case .leveledOverTime(_, let press): "rideReport.\(press)"
        case .voiceMatchRefused(_, let press): "voiceMatchRefused.\(press)"
        case .transcriptImported(_, let press): "transcriptImported.\(press)"
        case .unusedFilesFailed: "unusedFilesFailed"
        case .archived: "archived"
        case .archiveSaved: "archiveSaved"
        case .archiveDamaged: "archiveDamaged"
        case .consentExpired: "consentExpired"
        case .duckNoSpeech(_, _, let press): "duckNoSpeech.\(press)"
        case .duckUnread(_, let press): "duckUnread.\(press)"
        case .syncMoved(_, _, let press): "syncMoved.\(press)"
        case .syncNoMatch(_, _, _, _, _, let press): "syncNoMatch.\(press)"
        case .takeSyncBroken(let take, _, _, _, _): "takeSyncBroken.\(take)"
        case .transcriptionStopped(_, let press): "transcriptionStopped.\(press)"
        case .noWordsFound(let press): "noWordsFound.\(press)"
        case .sessionImported(_, let press): "sessionImported.\(press)"
        }
    }

    var kind: Kind {
        switch self {
        case .playbackStopped, .lowRecordTime, .useHeadphones, .monitorHeadphones, .chaptersDropped,
            .chapterImagesOmitted, .titleMissing, .transcriptLeftOut, .duckNoSpeech, .duckUnread, .takeSyncBroken,
            .transcriptImported, .transcriptionStopped, .exportSetStopped, .exportSetDropped, .voiceMatchRefused,
            .syncNoMatch, .stemsClipped, .stemsMixClipped, .stemsStopped, .sessionImported, .leveledOverTime,
            .exportSetDone:
            .warning
        case .missingMedia, .unusedFilesFailed, .archiveDamaged: .error
        case .archived, .archiveSaved, .consentExpired, .noiseUnchanged, .noWordsFound: .info
        case .syncMoved(let moved, _, _): moved.needsCheck ? .warning : .info
        case .levelReport(let report, _): report.atLimit > 0 || report.unmeasured > 0 ? .warning : .info
        case .soundRepaired(let result, _): result.drop > 0 ? .warning : .info
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
        case .exportSetDone(_, let old): L10n.oldFilesText(old)
        case .exportSetStopped(let written, let count): L10n.bannerExportSetStopped.format(written, count)
        case .exportSetDropped(let marker): L10n.bannerExportSetDropped.format(marker.name)
        case .stemsClipped(let names): stemsClippedText(names)
        case .stemsMixClipped: L10n.bannerStemsMixClipped.text
        case .stemsStopped: L10n.bannerStemsStopped.text
        case .chaptersDropped(let names, let file):
            L10n.bannerExportChapterDropped.format(file, names.joined(separator: ", "))
        case .chapterImagesOmitted(let file): L10n.bannerExportChapterImagesOmitted.format(file)
        case .titleMissing(let file): L10n.bannerExportTitleMissing.format(file)
        case .transcriptLeftOut(let count, let file): L10n.bannerTranscriptLeftOut.format(file, count)
        case .levelReport(let report, _): L10n.message(for: report)
        case .transcriptImported(let text, _): text
        case .noiseUnchanged: L10n.denoiseUnchanged.text
        case .soundRepaired(let result, _): L10n.repairResult(result)
        case .leveledOverTime(let result, _): L10n.rideResult(result)
        case .voiceMatchRefused(let text, _): text
        case .unusedFilesFailed(let paths): L10n.bannerUnusedFailed.format(paths.joined(separator: ", "))
        case .archived: L10n.bannerArchived.text
        case .archiveSaved(let net) where net > 0:
            L10n.bannerArchiveSaved.format(L10n.bytes(net)) + " " + L10n.bannerArchiveSnapshot.text
        case .archiveSaved: L10n.bannerArchiveNoSpace.text
        case .archiveDamaged(let paths): L10n.bannerArchiveDamaged.format(paths.joined(separator: ", "))
        case .consentExpired(let agent?): L10n.bannerConsentExpired.format(agent)
        case .consentExpired(nil): L10n.bannerConsentExpiredUnnamed.text
        case .duckNoSpeech(let threshold, let unread, _) where unread.isEmpty: L10n.errorDuckNoSpeech.format(threshold)
        case .duckNoSpeech(let threshold, let unread, let press):
            L10n.errorDuckNoSpeech.format(threshold) + " " + WindowBanner.duckUnread(unread, press: press).text
        case .duckUnread(let paths, _): L10n.bannerDuckUnread.format(paths.joined(separator: ", "))
        case .syncMoved(let moved, _, _): moved.text()
        case .syncNoMatch(_, _, let clipName, let trackName, _, _): syncNoMatchText(clip: clipName, track: trackName)
        case .takeSyncBroken(let take, let from, let rate, let agent, _):
            takeSyncBreakText(take: take, from: from, rate: rate, agent: agent)
        case .transcriptionStopped: L10n.transcribeStopped.text
        case .noWordsFound: L10n.transcribeNoWords.text
        case .sessionImported(let text, _): text
        }
    }

    /// VoiceOver reads a new banner at this priority. Nil: no announcement.
    var announcement: NSAccessibilityPriorityLevel? {
        switch self {
        case .playbackStopped, .lowRecordTime, .useHeadphones, .monitorHeadphones: .high
        case .missingMedia, .exportReport, .exportSetDone, .exportSetStopped, .exportSetDropped, .stemsClipped,
            .stemsMixClipped, .stemsStopped, .chaptersDropped, .chapterImagesOmitted, .titleMissing, .transcriptLeftOut,
            .levelReport, .noiseUnchanged, .soundRepaired, .leveledOverTime, .voiceMatchRefused,
            .transcriptImported, .archived, .archiveSaved, .archiveDamaged, .unusedFilesFailed, .consentExpired,
            .duckNoSpeech, .duckUnread, .takeSyncBroken,
            .transcriptionStopped, .noWordsFound, .syncMoved, .syncNoMatch:
            .medium
        case .sessionImported: nil
        }
    }
}

/// What VoiceOver hears when a set or a stem export ends: "Exported 10 files to <folder>.", then the
/// loudness range of the files.
func exportSetDoneText(_ files: [URL], _ low: Double?, _ high: Double?) -> String {
    let folder = files.first.map { $0.deletingLastPathComponent().path(percentEncoded: false) } ?? ""
    var text = L10n.announceExportSetDone.format(files.count, folder)
    if let low, let high {
        text += " " + L10n.announceExportSetLoudness.format(L10n.loudnessNumber(low), L10n.loudnessNumber(high))
    }
    return text
}

/// "The stem files a.wav, b.wav clip over 0 dBFS and won't add up to the mix." `text` gives the value of a key.
func stemsClippedText(_ names: [String], text: (L10n) -> String = { $0.text }) -> String {
    String(format: text(.bannerStemsClipped), names.joined(separator: ", "))
}

/// The text of the take sync banner: "Claude Code moved part of take 4, which is now out of sync with
/// its recording from 0:21:07." `text` gives the value of a key.
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
