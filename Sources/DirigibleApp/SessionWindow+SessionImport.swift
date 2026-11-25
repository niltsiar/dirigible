import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The value of the markers box of the Import Session panel.
@Observable @MainActor final class SessionImportChoice {
    var markers: Bool

    init(markers: Bool) { self.markers = markers }
}

/// The open panel of File > Import Session (decision 0075): session packages only, the message that
/// tells it from Open, and the markers box, which starts off and keeps the last choice of an import.
@MainActor enum SessionImportPanel {
    static let markersKey = "importSessionMarkers"

    static func make(defaults: UserDefaults?) -> (panel: NSOpenPanel, choice: SessionImportChoice) {
        let choice = SessionImportChoice(markers: defaults?.bool(forKey: markersKey) ?? false)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [AppDelegate.sessionType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L10n.importSessionPanelMessage.text
        panel.accessoryView = NSHostingView(rootView: SessionImportAccessory(choice: choice))
        panel.isAccessoryViewDisclosed = true
        return (panel, choice)
    }

    /// Keeps the box value of an import for the next panel.
    static func remember(_ choice: SessionImportChoice, in defaults: UserDefaults?) {
        defaults?.set(choice.markers, forKey: markersKey)
    }
}

private struct SessionImportAccessory: View {
    @Bindable var choice: SessionImportChoice

    var body: some View {
        Toggle(L10n.importSessionPanelMarkers.key, isOn: $choice.markers)
            .padding()
            .frame(width: 420, alignment: .leading)
    }
}

extension SessionWindow {
    /// File > Import Session: the open panel as a sheet of the window, then the import.
    func chooseSessionImport() {
        guard canImport, let window else { return }
        let defaults = app?.defaults
        let (panel, choice) = SessionImportPanel.make(defaults: defaults)
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                SessionImportPanel.remember(choice, in: defaults)
                self?.startSessionImport(url, markers: choice.markers)
            }
        }
    }

    /// Imports the tracks of the package at `source` at their recorded positions (offset 0), as one
    /// undo step. The banner "Importing <name>" with Cancel shows after 0.5 s, as for a paste from
    /// another package. Then the new tracks and their clips are selected, the first new track
    /// scrolls into view, and the result line shows and is announced. A refusal shows its alert.
    func startSessionImport(_ source: URL, markers: Bool) {
        commitDrafts()
        guard canImport, let studio = idleStudio else { return }
        let name = source.deletingPathExtension().lastPathComponent
        importJob = ImportJob(visible: false)
        let wait = bannerWait
        let shown = Task { [weak self] in
            await wait()
            guard let self, !Task.isCancelled, importJob != nil else { return }
            importJob?.visible = true
            chrome?.announce(L10n.importBanner.format(name), .high)
        }
        importJob?.task = Task { [weak self] in
            do throws(StudioError) {
                let imported = try await studio.importSession(source, markers: markers) { [weak self] in
                    self?.importProgressed($0)
                }
                shown.cancel()
                self?.finishSessionImport(imported, in: studio)
            } catch .sessionImport(.paste(.cancelled), _) {
                shown.cancel()
            } catch {
                shown.cancel()
                self?.alert = .error(error)
            }
            self?.importJob = nil
        }
    }

    /// Selects the new tracks with a range over all their clips, so the move and nudge keys act on
    /// the new clips, scrolls the first new track into view, and announces the result line. A line
    /// that tells of a muted call track or a marker that was left out shows as a warning banner too.
    private func finishSessionImport(_ imported: SessionImported, in studio: Studio) {
        let session = studio.session
        let clips = imported.tracks.flatMap { session.track($0).map { Array($0.clips) } ?? [] }
        let start = clips.map(\.start).min()
        timeline.selection = .range(
            Marks(inPoint: start, outPoint: clips.map(\.end).max(), tracks: Set(imported.tracks)))
        if let first = imported.tracks.first, let lane = session.tracks.firstIndex(where: { $0.id == first }) {
            timelineView?.reveal(frame: start ?? .zero, lane: lane)
        }
        let line = L10n.sessionImportLine(
            tracks: imported.tracks.count, muted: imported.mutedCallTracks, leftOut: imported.leftOutMarkers)
        if imported.mutedCallTracks > 0 || imported.leftOutMarkers > 0 {
            sessionImportPresses += 1
            sessionImportReport = ToolBannerShown(
                banner: .sessionImported(line, press: sessionImportPresses), revision: studio.sessionRevision)
        }
        chrome?.announce(line, .high)
    }
}
