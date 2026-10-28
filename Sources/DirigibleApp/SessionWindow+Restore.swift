import DirigibleCore
import DirigibleTimeline
import SwiftUI

extension TimelineCommand {
    /// Tools > Restore Original Audio (decision 0057 D6): after Reduce Noise, in its own group.
    static let restoreOriginalItem = MenuItem(
        command: .restoreOriginal, title: .menuToolsRestoreOriginal, key: "o", modifiers: [.command, .shift])
}

extension SessionWindow {
    /// The clips that Restore Original Audio takes: the clips of `Selection.clipsToLevel(in:)` on a
    /// rendered file, in session order. An empty selection has none.
    func restoreClips(in session: Session) -> [ClipID] {
        guard let selected = timeline.selection.clipsToLevel(in: session) else { return [] }
        return session.tracks.flatMap(\.clips)
            .filter { selected.contains($0.id) && session.files[$0.file]?.origin != nil }.map(\.id)
    }

    /// Moves each clip that Restore Original Audio takes to the root file of its render chain, at
    /// the frame that it played, with the added gain taken off: one edit, no file I/O. A selection
    /// with no such clip beeps.
    func restoreOriginal() {
        guard importJob == nil, let studio = idleStudio else { return }
        let clips = restoreClips(in: studio.session)
        guard !clips.isEmpty else { return beep() }
        edit(ripple: false) { s throws(SessionError) in try s.restoreOriginals(clips) }
    }
}
