import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// The running import of a window (decision 0040). The banner row shows it with the file name of
/// `Studio.importRun`.
struct ImportJob {
    var progress = 0.0
    var task: Task<Void, Never>?
    /// False until the banner shows: a paste shows it only after 0.5 s, so a clone shows none
    /// (`ui-panel.md` item 1). An import shows it at once.
    var visible = true
}

/// The target of File > Import Audio (decision 0040): the playhead on the one track that the
/// headers show as selected, else a new track. A clip set selects no track (decision 0038).
func importTarget(_ selection: Selection, in session: Session, playhead: Frames) -> ImportTarget {
    let tracks = selection.headerTracks(in: session)
    return ImportTarget(track: tracks.count == 1 ? tracks[0] : nil, start: playhead)
}

extension StudioError {
    /// A refusal of one file that does not stop a chain of imports (run 13c): the other files
    /// can still import.
    var skipsFile: Bool {
        switch self {
        case .audioImport(.notAudio), .audioImport(.tooManyChannels), .audioImport(.notDownloaded): true
        default: false
        }
    }
}

extension SessionWindow {
    /// File > Import Audio… is on: the studio is idle, no take waits, and no import runs.
    var canImport: Bool { importJob == nil && idleStudio.map { $0.pendingTake == nil } == true }

    /// File > Import Audio…: the open panel as a sheet of the window, then the import.
    func chooseImport() {
        guard canImport, let window, let app else { return }
        app.chooseImport(window) { [weak self] url in
            guard let self, let url, let studio = idleStudio else { return }
            startImport([url], to: importTarget(timeline.selection, in: studio.session, playhead: studio.playhead))
        }
    }

    /// Imports `urls` one after the other at `target`, with one undo entry each (run 13c). It first
    /// saves the typed names and inspector value. The banner shows the name of each file, the
    /// progress, and Cancel. The chain skips a file that is not audio, has more than 2 channels,
    /// or is not downloaded; a cancel or another error stops it. At the end, the new clips are
    /// selected, and one alert gives the error of each file that did not import and the names of
    /// the files after a stop. A cancel shows the alert only for skipped files.
    func startImport(_ urls: [URL], to target: ImportTarget) {
        commitNames()
        guard canImport, let studio = idleStudio, !urls.isEmpty else { return }
        importJob = ImportJob()
        importJob?.task = Task { [weak self] in
            var (clips, errors, notImported) = ([ClipID](), [StudioError](), [String]())
            chain: for (n, url) in urls.enumerated() {
                self?.importJob?.progress = 0
                self?.chrome?.announce(L10n.importBanner.format(url.lastPathComponent), .high)
                do throws(StudioError) {
                    clips.append(
                        try await studio.importAudio(url, to: target) { [weak self] in self?.importProgressed($0) })
                } catch .audioImport(.cancelled) {
                    break chain
                } catch {
                    errors.append(error)
                    guard error.skipsFile else {
                        notImported = urls[(n + 1)...].map(\.lastPathComponent)
                        break chain
                    }
                }
            }
            if let set = ClipSet(Set(clips)) { self?.timeline.selection = .clips(set) }
            if !errors.isEmpty {
                self?.alert = urls.count == 1 ? .error(errors[0]) : .importChain(errors, notImported: notImported)
            }
            self?.importJob = nil
        }
    }

    /// A progress hop of the running import. Hops can arrive out of order, so the bar keeps the
    /// largest fraction.
    func importProgressed(_ fraction: Double) {
        if let progress = importJob?.progress { importJob?.progress = max(progress, fraction) }
    }

    /// The Cancel button of the banner. The import ends within one block.
    func cancelImport() { importJob?.task?.cancel() }
}
