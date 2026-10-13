import DirigibleCore
import SwiftUI

/// One row of the Remove Unused Files sheet (`ui-panel.md` of run 2026-10-12-remove-unused-files).
struct UnusedFileRow: Identifiable, Equatable {
    let id: String
    let bytes: Int64
    let reason: L10n

    /// The rows of `scan`, the largest file first.
    static func rows(_ scan: UnusedFiles) -> [UnusedFileRow] {
        scan.items.map { item in
            let reason: L10n = if case .pool = item.kind { .sheetUnusedReasonPool } else { .sheetUnusedReasonStray }
            return UnusedFileRow(id: item.path, bytes: item.bytes, reason: reason)
        }
        .sorted { ($1.bytes, $0.id) < ($0.bytes, $1.id) }
    }
}

/// The confirmation of File > Remove Unused Files (decision 0047): the list, the total, the kept
/// line, and the Trash note. Cancel is the default button (Return and Escape); Move to Trash is
/// destructive and has no key (HIG: a destructive button is not the default).
struct UnusedFilesSheet: View {
    let model: SessionWindow
    let scan: UnusedFiles

    var body: some View {
        let rows = UnusedFileRow.rows(scan)
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.sheetUnusedTitle.key).font(.headline)
            Table(rows) {
                TableColumn(L10n.sheetUnusedName.key) { Text(verbatim: $0.id) }
                TableColumn(L10n.sheetUnusedSize.key) { Text(verbatim: L10n.bytes($0.bytes)) }.width(90)
                TableColumn(L10n.sheetUnusedReason.key) { Text($0.reason.key) }.width(150)
            }
            .frame(width: 560, height: 220)
            Text(verbatim: L10n.sheetUnusedTotal.format(rows.count, L10n.bytes(rows.map(\.bytes).reduce(0, +))))
            if let kept = L10n.keptLine(scan.kept) { Text(verbatim: kept) }
            Text(L10n.sheetUnusedFootnote.key).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.alertCancel.key) { model.unusedFiles = nil }.keyboardShortcut(.defaultAction)
                Button(L10n.sheetUnusedMove.key, role: .destructive) { model.moveUnusedFiles(scan) }
            }
        }
        .padding(20)
        // A button has one key, so Esc has a second Cancel with no size: the sheet takes Esc as
        // a key equivalent with no focus, as the Cancel of the export sheet.
        .background {
            Button(L10n.alertCancel.key) { model.unusedFiles = nil }.keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }
}

extension L10n {
    /// "Kept for a backup or Undo: N (size)", or nil when no file is kept.
    static func keptLine(_ kept: UnusedFiles.Kept) -> String? {
        kept.count == 0 ? nil : sheetUnusedKept.format(kept.count, bytes(kept.bytes))
    }
}
