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
    case menuFileShowClips = "menu.file.show.clips"
    case menuFileExport = "menu.file.export"
    case menuFileExportSelection = "menu.file.export.selection"
    case menuTrack = "menu.track"
    case menuTrackAdd = "menu.track.add"
    case menuTrackRemove = "menu.track.remove"
    case menuRecord = "menu.record"
    case menuRecordStart = "menu.record.start"
    case menuRecordRetry = "menu.record.retry"
    case menuRecordLeaveUnreadable = "menu.record.leave.unreadable"
    case menuUnplacedPlace = "menu.unplaced.place"
    case menuUnplacedPlacePlayhead = "menu.unplaced.place.playhead"
    case menuRecordMonitor = "menu.record.monitor"
    case menuTransport = "menu.transport"
    case menuTransportPlay = "menu.transport.play"
    case menuTransportStop = "menu.transport.stop"
    case menuTransportReturn = "menu.transport.return"
    case menuTransportReverse = "menu.transport.reverse"
    case menuTransportPause = "menu.transport.pause"
    case menuTransportForward = "menu.transport.forward"
    case menuTransportSlowReverse = "menu.transport.slow.reverse"
    case menuTransportSlowForward = "menu.transport.slow.forward"
    case menuTransportStart = "menu.transport.start"
    case menuTransportEnd = "menu.transport.end"
    case menuTransportPrevious = "menu.transport.previous"
    case menuTransportNext = "menu.transport.next"
    case menuWindowStart = "menu.window.start"
    case menuViewZoomIn = "menu.view.zoom.in"
    case menuViewZoomOut = "menu.view.zoom.out"
    case menuViewZoomFit = "menu.view.zoom.fit"
    case menuViewZoomSelection = "menu.view.zoom.selection"
    case menuViewZoomBack = "menu.view.zoom.back"
    case menuViewZoomForward = "menu.view.zoom.forward"
    case menuViewPagePrevious = "menu.view.page.previous"
    case menuViewPageNext = "menu.view.page.next"
    case menuViewTracksTaller = "menu.view.tracks.taller"
    case menuViewTracksShorter = "menu.view.tracks.shorter"
    case menuViewTracksFit = "menu.view.tracks.fit"
    case menuViewFollow = "menu.view.follow"
    case menuEditIn = "menu.edit.in"
    case menuEditOut = "menu.edit.out"
    case menuEditDeselect = "menu.edit.deselect"
    case menuEditCut = "menu.edit.cut"
    case menuEditCopy = "menu.edit.copy"
    case menuEditPaste = "menu.edit.paste"
    case menuEditDelete = "menu.edit.delete"
    case menuEditSelectAll = "menu.edit.select.all"
    case menuEditSplit = "menu.edit.split"
    case menuEditNudgeLeft = "menu.edit.nudge.left"
    case menuEditNudgeRight = "menu.edit.nudge.right"
    case menuMarkers = "menu.markers"
    case menuMarkersAdd = "menu.markers.add"
    case menuMarkersAddChapter = "menu.markers.add.chapter"
    case menuMarkersRename = "menu.markers.rename"
    case menuMarkersMove = "menu.markers.move"
    case menuMarkersDelete = "menu.markers.delete"
    case menuMarkersPrevious = "menu.markers.previous"
    case menuMarkersNext = "menu.markers.next"

    case panelNewName = "panel.new.name"
    case panelExportFormat = "panel.export.format"
    case panelExportFormatWAV = "panel.export.format.wav"
    case panelExportFormatAAC = "panel.export.format.aac"
    case panelExportFormatFLAC = "panel.export.format.flac"
    case panelExportBits = "panel.export.bits"
    case panelExportBitrate = "panel.export.bitrate"
    case panelExportBitrateValue = "panel.export.bitrate.value"
    case panelExportChannels = "panel.export.channels"
    case panelExportChannelsStereo = "panel.export.channels.stereo"
    case panelExportChannelsMono = "panel.export.channels.mono"
    case panelExportRate = "panel.export.rate"
    case panelExportRateSession = "panel.export.rate.session"
    case panelExportRate44100 = "panel.export.rate.44100"
    case panelExportRate48000 = "panel.export.rate.48000"
    case sheetExportTitle = "sheet.export.title"
    case sheetExportCancel = "sheet.export.cancel"
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
    case alertMarkerRename = "alert.marker.rename"
    case alertExportMissing = "alert.export.missing"
    case alertExportConfirm = "alert.export.confirm"
    case alertExported = "alert.exported"

    case emptyTitle = "empty.title"
    case emptySteps = "empty.steps"
    case trackDefaultName = "track.default.name"
    case markerDefaultName = "marker.default.name"
    case chapterDefaultName = "chapter.default.name"
    case trackName = "track.name"
    case trackArm = "track.arm"
    case headerHandle = "timeline.header.handle"
    case trackLayoutMono = "track.layout.mono"
    case trackLayoutStereo = "track.layout.stereo"
    case trackRoute = "track.route"
    case trackRouteNone = "track.route.none"
    case trackRouteChoose = "track.route.choose"
    case trackRouteChannel = "track.route.channel"
    case trackRouteChannels = "track.route.channels"
    case trackRouteMissing = "track.route.missing"
    case trackStateDeviceLost = "track.state.device.lost"
    case trackStateWriteFailed = "track.state.write.failed"
    case trackStateRetryStopped = "track.state.retry.stopped"
    case trackDropped = "track.dropped"
    case takeRecording = "take.recording"
    case takeFinishing = "take.finishing"
    case takePlacing = "take.placing"
    case takePending = "take.pending"
    case takePendingLeaveHint = "take.pending.leave.hint"
    case takePendingSpace = "take.pending.space"
    case takeEnded = "take.ended"
    case takeEndedDiskLow = "take.ended.disk.low"
    case takeGapDeviceLost = "take.gap.device.lost"
    case takeGapWriteFailed = "take.gap.write.failed"
    case takeDropped = "take.dropped"
    case takeRecovered = "take.recovered"
    case takeUnplaced = "take.unplaced"
    case takeUnplacedRedo = "take.unplaced.redo"
    case bannerSaveError = "banner.save.error"
    case transportRecord = "transport.record"
    case transportStop = "transport.stop"
    case transportPlay = "transport.play"
    case transportRecordOver = "transport.record.over"
    case transportStopOutputChanged = "transport.stop.output.changed"
    case transportStopOutputUnavailable = "transport.stop.output.unavailable"
    case transportStopPackageUnavailable = "transport.stop.package.unavailable"
    case transportStopNoDescriptor = "transport.stop.no.descriptor"
    case mediaMissing = "media.missing"
    case timelineAccessibility = "timeline.accessibility"
    case timelineOverview = "timeline.overview"
    case timelineOverviewValue = "timeline.overview.value"
    case timelineOverviewFit = "timeline.overview.fit"
    case timelineOverviewHelp = "timeline.overview.help"
    case toolbarMonitor = "toolbar.monitor"
    case toolbarTime = "toolbar.time"
    case toolbarZoomFit = "toolbar.zoom.fit"
    case toolbarExport = "toolbar.export"
    case toolbarTooltip = "toolbar.tooltip"
    case keySpace = "key.space"
    case subtitleTracks = "subtitle.tracks"
    case subtitleRecordTime = "subtitle.record.time"
    case bannerLowRecordTime = "banner.low.record.time"
    case bannerKindWarning = "banner.kind.warning"
    case bannerKindError = "banner.kind.error"
    case bannerKindInfo = "banner.kind.info"
    case startTitle = "start.title"
    case startVersion = "start.version"
    case startOpenOther = "start.open.other"

    case errorBusy = "error.studio.busy"
    case errorLocked = "error.studio.locked"
    case errorNoRoute = "error.studio.no.route"
    case errorDeviceMissing = "error.studio.device.missing"
    case errorChannelOutOfRange = "error.studio.channel.range"
    case errorChannelInUse = "error.studio.channel.in.use"
    case errorDiskLow = "error.studio.disk.low"
    case errorPlacementSpace = "error.placement.space"
    case errorMicrophoneDenied = "error.microphone.denied"
    case errorMicrophoneRestricted = "error.microphone.restricted"
    case errorSessionName = "error.session.name"
    case errorSessionLayout = "error.session.layout"
    case errorSessionTrackInTake = "error.session.track.in.take"
    case errorSessionTrackCount = "error.session.track.count"
    case errorSessionOther = "error.session.other"
    case errorFileUnreadable = "error.file.unreadable"
    case errorFileNewer = "error.file.newer"
    case errorFileRead = "error.file.read"
    case errorFileWrite = "error.file.write"
    case errorFileInternal = "error.file.internal"
    case errorFileMoved = "error.file.moved"
    case errorFileExists = "error.file.exists"
    case errorFinalizeRead = "error.finalize.read"
    case errorFinalizeUnreadable = "error.finalize.unreadable"
    case errorFinalizeWrite = "error.finalize.write"
    case errorSegmentNotUnplaced = "error.segment.not.unplaced"
    case errorSegmentNoSidecar = "error.segment.no.sidecar"
    case errorSegmentNewer = "error.segment.newer"
    case errorSegmentNewerAnchor = "error.segment.newer.anchor"
    case errorSegmentBadAudio = "error.segment.bad.audio"
    case errorSegmentBeforeStart = "error.segment.before.start"
    case errorSegmentNoAlignment = "error.segment.no.alignment"
    case errorSegmentWAVInUse = "error.segment.wav.in.use"
    case errorExportExists = "error.export.exists"
    case errorExportRate = "error.export.rate"
    case errorExportDiskFull = "error.export.disk.full"
    case errorExportWrite = "error.export.write"
    case errorExportMove = "error.export.move"
    case errorExportOpen = "error.export.open"
    case errorExportPackage = "error.export.package"
    case errorExportYielded = "error.export.yielded"

    /// For `Text` and `Button`: SwiftUI looks the key up in `Bundle.main`.
    var key: LocalizedStringKey { LocalizedStringKey(rawValue) }

    /// The value from the table of the app language in `Bundle.main`.
    var text: String { Bundle.main.localizedString(forKey: rawValue, value: nil, table: nil) }

    /// The value with its format specifiers filled.
    func format(_ arguments: any CVarArg...) -> String {
        String(format: text, locale: .current, arguments: arguments)
    }

    /// A byte count in the units of the Finder.
    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

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
        case .placementSpace(let needed, let free):
            return errorPlacementSpace.format(bytes(needed), bytes(free))
        case .microphoneAccess(.restricted): return errorMicrophoneRestricted.text
        case .microphoneAccess(.denied), .microphoneAccess(.notDetermined): return errorMicrophoneDenied.text
        case .session(let error): return message(for: error, name: name)
        case .file(let error): return message(for: error)
        case .finalize(.readFailed(let file, let errno)): return errorFinalizeRead.format(file, Int(errno))
        case .finalize(.writeFailed(let file, let status)): return errorFinalizeWrite.format(file, Int(status))
        case .finalize(.segmentUnreadable(_, let file, let errno)):
            return errorFinalizeUnreadable.format(file, Int(errno))
        case .export(let error): return message(for: error)
        case .exportYielded: return errorExportYielded.text
        case .segment(_, .session(let error)): return message(for: error, name: name)
        case .segment(let segment, let fault): return message(for: fault).format(segment.stem)
        }
    }

    /// The key of a placement refusal (decision 0021). A session refusal has the session text.
    private static func message(for fault: SegmentFault) -> L10n {
        switch fault {
        case .notUnplaced: errorSegmentNotUnplaced
        case .noSidecar: errorSegmentNoSidecar
        case .newerSidecar: errorSegmentNewer
        case .badAudio: errorSegmentBadAudio
        case .beforeTimeline: errorSegmentBeforeStart
        case .noAlignment: errorSegmentNoAlignment
        case .newerAnchor: errorSegmentNewerAnchor
        case .wavInUse: errorSegmentWAVInUse
        case .session: errorSessionOther
        }
    }

    /// The text of an export error. The window shows no alert for a cancel, so `.cancelled` has
    /// no key.
    private static func message(for error: ExportError) -> String {
        switch error {
        case .exists: errorExportExists.text
        case .rateNotSupported(let rate): errorExportRate.format(rate)
        case .diskFull: errorExportDiskFull.text
        case .writeFailed(let status): errorExportWrite.format(Int(status))
        case .moveFailed(let code): errorExportMove.format(Int(code))
        case .openFailed(let code): errorExportOpen.format(Int(code))
        case .packageUnavailable: errorExportPackage.text
        case .cancelled: ""
        }
    }

    /// The text of a stop of playback that the user did not ask for.
    static func message(for stop: PlaybackStop) -> String {
        switch stop {
        case .outputChanged: transportStopOutputChanged.text
        case .outputUnavailable(let code): transportStopOutputUnavailable.format(code)
        case .packageUnavailable: transportStopPackageUnavailable.text
        case .noFreeDescriptor(let code): transportStopNoDescriptor.format(code)
        }
    }

    private static func message(for error: SessionError, name: (TrackID) -> String) -> String {
        switch error {
        case .invalidText: return errorSessionName.text
        case .layoutMismatch(let track, _): return errorSessionLayout.format(name(track))
        case .trackInRecording(let track): return errorSessionTrackInTake.format(name(track))
        case .trackCount(let count): return errorSessionTrackCount.format(count)
        // The window never makes these edits: they are bugs, not user errors.
        case .duplicateID, .unknownCapture, .unknownFile, .unknownTrack, .unknownClip, .unknownMarker,
            .captureInUse, .invalidCapture, .fileInUse, .invalidRoute, .invalidPath, .frameOutOfRange,
            .takeOutOfRange, .clipOutsideFile, .overlap, .frameOutsideClip:
            return errorSessionOther.text
        }
    }

    private static func message(for error: SessionFileError) -> String {
        switch error {
        case .unsupportedVersion: return errorFileNewer.text
        case .malformedXML, .invalidChannelCount, .missingAttribute, .invalidValue, .invalidSession:
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
