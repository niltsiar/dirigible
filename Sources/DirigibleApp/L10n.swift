import DirigibleAudio
import DirigibleCore
import Foundation
import SwiftUI

/// The key of each UI string (decision 0010). The raw value is the key in
/// `Support/Resources/<lang>.lproj/Localizable.strings`. Code names a key only through this enum,
/// and `LocalizationTests` checks both tables against it.
enum L10n: String, CaseIterable {
    case menuFileNew = "menu.file.new"
    case menuFileOpen = "menu.file.open"
    case menuFileOpenRecent = "menu.file.open.recent"
    case menuTrack = "menu.track"
    case menuTrackAdd = "menu.track.add"
    case menuRecord = "menu.record"
    case menuRecordStart = "menu.record.start"
    case menuRecordStop = "menu.record.stop"
    case menuRecordRetry = "menu.record.retry"

    case panelNewName = "panel.new.name"
    case windowOpening = "window.opening"
    case windowRecovering = "window.recovering"
    case windowTryAgain = "window.try.again"
    case alertOK = "alert.ok"
    case alertCancel = "alert.cancel"
    case alertCloseRecording = "alert.close.recording"
    case alertCloseRecordingConfirm = "alert.close.recording.confirm"
    case alertCloseUnsaved = "alert.close.unsaved"
    case alertCloseUnsavedConfirm = "alert.close.unsaved.confirm"
    case alertQuitRecording = "alert.quit.recording"
    case alertQuitRecordingConfirm = "alert.quit.recording.confirm"
    case alertQuitUnsaved = "alert.quit.unsaved"
    case alertQuitUnsavedConfirm = "alert.quit.unsaved.confirm"
    case alertMicrophoneSettings = "alert.microphone.settings"

    case trackNone = "track.none"
    case trackDefaultName = "track.default.name"
    case trackName = "track.name"
    case trackArm = "track.arm"
    case trackLayoutMono = "track.layout.mono"
    case trackLayoutStereo = "track.layout.stereo"
    case trackRoute = "track.route"
    case trackRouteNone = "track.route.none"
    case trackRouteChannel = "track.route.channel"
    case trackRouteChannels = "track.route.channels"
    case trackRouteMissing = "track.route.missing"
    case trackStateDeviceLost = "track.state.device.lost"
    case trackStateWriteFailed = "track.state.write.failed"
    case trackStateRetryStopped = "track.state.retry.stopped"
    case trackDropped = "track.dropped"
    case takeRecording = "take.recording"
    case takeFinishing = "take.finishing"
    case takePending = "take.pending"
    case takePendingSpace = "take.pending.space"
    case takeEnded = "take.ended"
    case takeEndedDiskLow = "take.ended.disk.low"
    case takeGapDeviceLost = "take.gap.device.lost"
    case takeGapWriteFailed = "take.gap.write.failed"
    case takeDropped = "take.dropped"
    case takeRecovered = "take.recovered"
    case takeUnplaced = "take.unplaced"
    case bannerSaveError = "banner.save.error"

    case errorBusy = "error.studio.busy"
    case errorLocked = "error.studio.locked"
    case errorNoRoute = "error.studio.no.route"
    case errorDeviceMissing = "error.studio.device.missing"
    case errorChannelOutOfRange = "error.studio.channel.range"
    case errorChannelInUse = "error.studio.channel.in.use"
    case errorDiskLow = "error.studio.disk.low"
    case errorMicrophoneDenied = "error.microphone.denied"
    case errorMicrophoneRestricted = "error.microphone.restricted"
    case errorSessionName = "error.session.name"
    case errorSessionLayout = "error.session.layout"
    case errorSessionTrackInTake = "error.session.track.in.take"
    case errorSessionOther = "error.session.other"
    case errorFileUnreadable = "error.file.unreadable"
    case errorFileRead = "error.file.read"
    case errorFileWrite = "error.file.write"
    case errorFileInternal = "error.file.internal"
    case errorFileMoved = "error.file.moved"
    case errorFileExists = "error.file.exists"
    case errorFinalizeRead = "error.finalize.read"
    case errorFinalizeWrite = "error.finalize.write"

    /// For `Text` and `Button`: SwiftUI looks the key up in `Bundle.main`.
    var key: LocalizedStringKey { LocalizedStringKey(rawValue) }

    /// The value from the table of the app language in `Bundle.main`.
    var text: String { Bundle.main.localizedString(forKey: rawValue, value: nil, table: nil) }

    /// The value with its format specifiers filled.
    func format(_ arguments: any CVarArg...) -> String {
        String(format: text, locale: .current, arguments: arguments)
    }

    /// The text of a library error. The switches have no `default`, so a new error case does not
    /// compile until it has a key. `session` gives the track names; without it, the text shows
    /// the track ID.
    static func message(for error: StudioError, session: Session? = nil) -> String {
        let name = { (id: TrackID) in session?.track(id)?.name ?? id.rawValue }
        switch error {
        case .busy: return errorBusy.text
        case .locked: return errorLocked.text
        case .noRoute(let track): return errorNoRoute.format(name(track))
        case .deviceMissing(let track): return errorDeviceMissing.format(name(track))
        case .channelOutOfRange(let track): return errorChannelOutOfRange.format(name(track))
        case .channelInUse(let first, let second): return errorChannelInUse.format(name(first), name(second))
        case .diskLow: return errorDiskLow.text
        case .microphoneAccess(.restricted): return errorMicrophoneRestricted.text
        case .microphoneAccess(.denied), .microphoneAccess(.notDetermined): return errorMicrophoneDenied.text
        case .session(let error): return message(for: error, name: name)
        case .file(let error): return message(for: error)
        case .finalize(.readFailed(let file, let errno)): return errorFinalizeRead.format(file, Int(errno))
        case .finalize(.writeFailed(let file, let status)): return errorFinalizeWrite.format(file, Int(status))
        }
    }

    private static func message(for error: SessionError, name: (TrackID) -> String) -> String {
        switch error {
        case .invalidText: return errorSessionName.text
        case .layoutMismatch(let track, _): return errorSessionLayout.format(name(track))
        case .trackInRecording(let track): return errorSessionTrackInTake.format(name(track))
        // The window never makes these edits: they are bugs, not user errors.
        case .duplicateID, .unknownCapture, .unknownFile, .unknownTrack, .unknownClip, .unknownMarker,
            .captureInUse, .invalidCapture, .fileInUse, .invalidRoute, .invalidPath, .frameOutOfRange,
            .takeOutOfRange, .clipOutsideFile, .overlap, .frameOutsideClip:
            return errorSessionOther.text
        }
    }

    private static func message(for error: SessionFileError) -> String {
        switch error {
        case .malformedXML, .unsupportedVersion, .invalidChannelCount, .missingAttribute, .invalidValue,
            .invalidSession:
            return errorFileUnreadable.text
        case .readFailed(let errno): return errorFileRead.format(Int(errno))
        case .writeFailed(_, let errno): return errorFileWrite.format(Int(errno))
        case .wouldNotReadBack: return errorFileInternal.text
        case .locked: return errorLocked.text
        case .packageMoved: return errorFileMoved.text
        case .exists: return errorFileExists.text
        }
    }
}
