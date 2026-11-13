import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// The edits of the index list that act on several rows. Each writes the rows through the index form
/// of `TimelineState.selectRows`, which seeks nowhere.
extension SessionWindow {
    /// Command-A in the list: the rows that the kind filter and the search show. The anchor stays
    /// while it shows.
    func selectAllIndexRows() {
        guard let session = studio?.session else { return }
        let pane = leadingPane
        let shown = pane.sessionIndex(for: session).rows(kind: pane.kind, search: pane.search, keeping: pane.editedRow)
        guard let first = shown.first else { return beep() }
        let picks = Set(shown.map(\.id))
        let anchor = timeline.anchorRow.flatMap { picks.contains($0) ? $0 : nil } ?? first.id
        timeline.selectRows(picks, anchor: anchor, form: .indexSet)
    }

    /// Takes each selected row that the kind filter and the search hide off the selection. It writes
    /// only when a row goes, so a command that drops nothing pushes nothing.
    func dropHiddenIndexRows() {
        let selected = timeline.selectedRows
        guard !selected.isEmpty, let session = studio?.session else { return }
        let pane = leadingPane
        let kept = pane.sessionIndex(for: session)
            .shownPicks(of: selected, kind: pane.kind, search: pane.search, keeping: pane.editedRow)
        guard kept != selected else { return }
        let anchor =
            timeline.anchorRow.flatMap { kept.contains($0) ? $0 : nil } ?? SessionIndex.first(of: kept, in: session)
        timeline.selectRows(kept, anchor: anchor, form: .indexSet)
    }
}
