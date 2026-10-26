import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// The running import of a window (decision 0040). The banner row shows it with the file name of
/// `Studio.importRun`.
struct ImportJob {
    var progress = 0.0
    /// The index of the file of a chain that `progress` is for. A paste is file 0.
    var file = 0
    var task: Task<Void, Never>?
    /// False until the banner shows: a paste and a split show it only after 0.5 s, so a clone or a
    /// short split shows none (`ui-panel.md` item 1). An import shows it at once.
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
    /// can still import. The switch names each import error, so a new case needs a choice.
    var skipsFile: Bool {
        guard case .audioImport(let error) = self else { return false }
        switch error {
        case .notAudio, .tooManyChannels, .notDownloaded: return true
        case .unreadable, .space, .cancelled, .write, .session: return false
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
        commitDrafts()
        guard canImport, let studio = idleStudio else { return }
        importJob = ImportJob()
        importJob?.task = Task { [weak self] in
            var (clips, errors, notImported) = ([ClipID](), [StudioError](), [String]())
            chain: for (n, url) in urls.enumerated() {
                self?.importJob?.progress = 0
                self?.importJob?.file = n
                self?.chrome?.announce(L10n.importBanner.format(url.lastPathComponent), .high)
                do throws(StudioError) {
                    clips.append(
                        try await studio.importAudio(url, to: target) { [weak self] in
                            self?.importProgressed($0, file: n)
                        })
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

    /// A progress hop of file `file` of the running import. Hops can arrive out of order, so the
    /// bar keeps the largest fraction. A hop of another file changes nothing.
    func importProgressed(_ fraction: Double, file: Int = 0) {
        if let job = importJob, job.file == file { importJob?.progress = max(job.progress, fraction) }
    }

    /// The Cancel button of the banner. The import ends within one block. An import that the
    /// window did not start, an agent import, ends through the studio (decision 0049).
    func cancelImport() {
        if let task = importJob?.task { task.cancel() } else { studio?.cancelImport() }
    }

    /// The fraction of the import bar: the job of the window first, which a chain resets for each
    /// file and a paste or an image fills, else the import of an agent in the studio.
    var importBarProgress: Double { importJob?.progress ?? studio?.importProgress ?? 0 }
}
