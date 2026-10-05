import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// The running import of a window (decision 0040). The banner row shows it with the file name of
/// `Studio.importRun`.
struct ImportJob {
    var progress = 0.0
    var task: Task<Void, Never>?
}

/// The target of File > Import Audio (decision 0040): the playhead on the one track that the
/// headers show as selected, else a new track. A clip set selects no track (decision 0038).
func importTarget(_ selection: Selection, in session: Session, playhead: Frames) -> ImportTarget {
    let tracks = selection.headerTracks(in: session)
    return ImportTarget(track: tracks.count == 1 ? tracks[0] : nil, start: playhead)
}

extension SessionWindow {
    /// File > Import Audio… is on: the studio is idle, no take waits, and no import runs.
    var canImport: Bool { importJob == nil && idleStudio.map { $0.pendingTake == nil } == true }

    /// File > Import Audio…: the open panel as a sheet of the window, then the import.
    func chooseImport() {
        commitNames()
        guard canImport, let window, let app else { return }
        app.chooseImport(window) { [weak self] url in
            guard let self, let url else { return }
            startImport(url)
        }
    }

    /// Imports `url` at the target of now. The banner shows the file name, the progress, and
    /// Cancel. After a success, the new clip is selected. A cancel shows nothing; another error
    /// shows its alert.
    func startImport(_ url: URL) {
        guard canImport, let studio = idleStudio else { return }
        let target = importTarget(timeline.selection, in: studio.session, playhead: studio.playhead)
        importJob = ImportJob()
        importJob?.task = Task { [weak self] in
            do throws(StudioError) {
                let clip = try await studio.importAudio(url, to: target) { [weak self] in self?.importProgressed($0) }
                self?.timeline.selection = ClipSet([clip]).map { .clips($0) } ?? .none
            } catch .audioImport(.cancelled) {
            } catch {
                self?.alert = .error(error)
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
