import DirigibleAudio
import DirigibleCore
import Foundation

extension StudioError {
    /// No `default` case: a new error case does not compile until it has a message.
    package func message(package: String) -> String {
        switch self {
        case .locked: SessionFileError.locked.message(package: package)
        case .busy: "\(package) is busy with a take."
        case .noRoute(let track): "track \"\(track)\" has no route."
        case .deviceMissing(let track): "the device of track \"\(track)\" is missing."
        case .channelOutOfRange(let track): "the device of track \"\(track)\" does not have its channel."
        case .channelInUse(let first, let second): "tracks \"\(first)\" and \"\(second)\" use the same channel."
        case .session(let error): error.message
        case .file(let error): error.message(package: package)
        case .finalize(.readFailed(let file, let code)), .finalize(.segmentUnreadable(_, let file, let code)):
            "cannot read \(package)/\(file): \(String(cString: strerror(code)))."
        case .finalize(.writeFailed(let file, let status)): "cannot write \(package)/\(file) (status \(status))."
        case .segment(let segment, let fault): fault.message(segment: segment)
        case .microphoneAccess:
            "the terminal has no microphone access. Allow it in System Settings > Privacy & Security > Microphone."
        case .diskLow: "the disk of \(package) has less than 1 GB free."
        case .appSourcesUnavailable: appSourcesUnavailableMessage
        case .placementSpace(let needed, let free):
            "the placement needs \(needed) bytes free on the disk of \(package); \(free) bytes are free."
        // No command exports through Studio; `dirigible export` calls `exportMix` (decision 0019).
        case .export(let error): "the export failed (\(error))."
        case .exportYielded: "a take in another studio stopped the export."
        // `liveExport` catches each `.exportParts` case first, and no command exports a set through Studio.
        case .exportParts(let error): "the export of the files failed (\(error))."
        case .exportPresets(.exists(let urls)): "an item is at \(urls.map(\.path).joined(separator: ", "))."
        case .exportPresets(.duplicateTargets(let urls)):
            "two presets give one file name: \(urls.map(\.path).joined(separator: ", "))."
        case .exportPresets(.rateNotSupported(let preset, let rate)):
            "preset \"\(preset.text)\" cannot write \(rate) Hz."
        case .exportPresets(.stopped(let stop)): "the preset export stopped (\(stop.error))."
        // `liveStems` catches each `.exportStems` case first, and no command exports stems through Studio.
        case .exportStems(let error): "the stem export failed (\(error))."
        case .template(let error): "the template copy failed (\(error))."
        case .templateYielded: "a take stopped the template copy."
        // No command imports through Studio; `dirigible import` calls `importAudio` (decision 0040).
        case .audioImport(let error): "the import failed (\(error))."
        case .importYielded: "a take in another studio stopped the import."
        case .paste(let error, _): "the paste failed (\(error))."
        case .sessionImport(let error, let source): error.message(source: source, package: package)
        case .sessionImportYielded: "a take in another studio stopped the session import."
        case .pasteYielded: "a take in another studio stopped the paste."
        case .split(let error): error.message
        case .splitYielded: "a take in another studio stopped the split."
        case .clipRender(let error): error.message
        case .clipRenderYielded: "a take in another studio stopped the clip render."
        case .rippleBlocked: "a ripple cannot move the timeline under a pending or split take."
        // No command sets the artwork through Studio; `episode set --artwork` calls `importArtwork`.
        case .artwork(let error): error.message
        // `file prune` calls `UnusedFiles` with no Studio.
        case .unusedFiles(let error): error.message(package: package)
        // No command levels through Studio; `dirigible level` calls `autoLevel`.
        case .levelCancelled: "the level was cancelled."
        case .duckCancelled: "the duck was cancelled."
        // No command reads through Studio; the read commands call `ReadWork.read`.
        case .readYielded: "a take stopped the read."
        case .readClosed: "the close of the window stopped the read."
        case .transcription(let error): error.message
        case .transcriptionYielded: "a take stopped the transcription."
        case .transcriptionCancelled: "the transcription was cancelled."
        case .duckRead(let code): audioReadMessage(POSIXError(POSIXErrorCode(rawValue: code) ?? .EMFILE))
        case .rideCancelled: "the level over time was cancelled."
        case .rideRead(let code): audioReadMessage(POSIXError(POSIXErrorCode(rawValue: code) ?? .EMFILE))
        case .rideFault(let file, let fault): "file \(file) \(ExportText.describe(fault)); no ride changed."
        case .tooLittleVoice(.reference, let seconds):
            "the reference clip has \(seconds) s of voice; Match Voice needs \(Studio.matchVoiceSeconds) s."
        case .tooLittleVoice(.track(let track), let seconds):
            "track \(track) has \(seconds) s of voice; Match Voice needs \(Studio.matchVoiceSeconds) s."
        case .noTargetTrack:
            "Match Voice leaves out music and effects tracks and the track of the reference clip, so no track is "
                + "left to match."
        case .rangeOutsideReference(let clip):
            "the range must lie inside the reference clip, frames \(clip.lowerBound) to \(clip.upperBound)."
        case .matchCancelled: "the voice match was cancelled."
        case .matchRead(let code): audioReadMessage(POSIXError(POSIXErrorCode(rawValue: code) ?? .EMFILE))
        case .matchFault(let file, let fault): "file \(file) \(ExportText.describe(fault)); no track changed."
        case .syncNoMatch: "No match: the clip audio was not found on the track."
        case .syncFile(let file, let fault): "file \(file) \(ExportText.describe(fault)); no clip moved."
        case .syncRead(let code): audioReadMessage(POSIXError(POSIXErrorCode(rawValue: code) ?? .EMFILE))
        case .syncCancelled: "the sync was cancelled."
        // No command or tool scans through Studio; `silences` calls `ReadWork.read`.
        case .silencesCancelled: "the silence scan was cancelled."
        case .silencesRead(let code): audioReadMessage(POSIXError(POSIXErrorCode(rawValue: code) ?? .EMFILE))
        case .silencesStale: "the tracks changed after the silence scan; scan again."
        case .silencesFaults(let faults):
            faults.sorted { $0.key < $1.key }.map { "file \($0.key) \(ExportText.describe($0.value))" }
                .joined(separator: "; ") + "; its clips would read as silence, so the scan gives no silence."
        case .writerDidNotStop(let name):
            "\(name) did not stop in time. The audio is safe in \(package)/Capture; open the package in "
                + "Dirigible to finish the take."
        case .outputTermUnavailable: "the output latency of the playback device did not read; a pre-roll take needs it."
        case .preRollStopped(let stop): "the pre-roll play stopped because \(stop.reason), so the take did not start."
        case .favoritesLocked: "another process or a window has the Favorites store open."
        case .favoritesDamaged(let error): "the Favorites store does not read (\(error.map { "\($0)" } ?? "a take"))."
        case .favoritesFile(let error): "the Favorites store failed (\(error))."
        case .favoritesCopy(let error): "the copy into the Favorites store failed (\(error))."
        case .favoritesYielded: "a take in another studio stopped the add to Favorites."
        case .archive(let fault): fault.message(package: package)
        case .archived: "\(package) is archived as FLAC. Run `dirigible file unarchive` first."
        }
    }
}

extension ArchiveFault {
    /// No `default` case: a new fault does not compile until it has a message.
    package func message(package: String) -> String {
        switch self {
        case .pendingTake: pendingTakeMessage(package)
        case .favoritesStore: "The Favorites store is never archived."
        case .space(let need, let free):
            "the audio files of \(package) need \(need) bytes free to convert; \(free) bytes are free."
        case .clip(.read(let file, let code)): "cannot read \(package)/\(file): \(String(cString: strerror(code)))."
        case .clip(.write(let file, let code)):
            "cannot write \(package)/\(file): \(String(cString: strerror(code)))."
        case .clip(.notArchivable(let path)): "\(package)/\(path) is not a 24-bit WAV of the session rate."
        case .clip(.nameTaken(let path)): "\(package)/\(path) has a file of other audio at its other name."
        case .clip(.mismatch(let path)): "\(package)/\(path) did not convert: its audio did not check."
        case .file(let error): error.message(package: package)
        case .cancelled: "the conversion of the audio files was cancelled."
        }
    }
}
