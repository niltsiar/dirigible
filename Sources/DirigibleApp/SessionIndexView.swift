import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// The leading pane of a session window (decision 0023): the search field, the kind filter, and
/// the list of the index. Its body reads the rows only through
/// `LeadingPaneState.sessionIndex(for:)`: it never reads the playhead or a field of
/// `SessionWindow.timeline`, which a lane scroll writes.
struct SessionIndexView: View {
    static let searchIdentifier = "index.search"

    let model: SessionWindow
    let studio: Studio

    /// What the list shows in place of rows.
    enum Empty: Equatable {
        case none, session, noResults

        /// An empty session shows its hint; rows hidden by the filter or the search show the
        /// no-results text.
        init(rows: Int, of all: Int) { self = rows > 0 ? .none : all == 0 ? .session : .noResults }
    }

    var body: some View {
        let pane = model.leadingPane
        let _ = pane.countBody()
        let index = pane.sessionIndex(for: studio.session)
        let rows = timePart(pane, "rows filter") {
            index.rows(kind: pane.kind, search: pane.search, keeping: pane.editedRow)
        }
        VStack(spacing: 8) {
            IndexSearchField(model: model, text: Bindable(pane).search)
            IndexKindFilter(kind: Bindable(pane).kind)
            SessionIndexTable(model: model, pane: pane, rows: rows, rate: studio.session.sampleRate)
                .overlay { emptyView(Empty(rows: rows.count, of: index.rows.count), search: pane.search) }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: pane.search) {
            pane.table?.mark.holdFollow(.search)
            model.dropHiddenIndexRows()
        }
        .onChange(of: pane.kind) { model.dropHiddenIndexRows() }
    }

    /// The text of the empty session with the key of Add Marker, as the menu shows it.
    static func hint(text: (L10n) -> String = { $0.text }) -> String {
        String(
            format: text(.indexEmptyHint), locale: .current,
            keyText(WindowCommand.timeline(.addMarker).menuItem.key))
    }

    @ViewBuilder private func emptyView(_ empty: Empty, search: String) -> some View {
        switch empty {
        case .none: EmptyView()
        case .session:
            ContentUnavailableView {
                Text(L10n.indexEmptySession.key)
            } description: {
                Text(verbatim: Self.hint())
            }
        case .noResults: ContentUnavailableView.search(text: search)
        }
    }
}

/// The search field as an `NSTextField` that `LeadingPaneState.searchField` holds: the window finds
/// it by that reference, not in the view tree. Esc and Down Arrow go to the window.
struct IndexSearchField: NSViewRepresentable {
    let model: SessionWindow
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> IndexSearchTextField {
        let field = IndexSearchTextField()
        field.placeholderString = L10n.indexSearchPlaceholder.text
        field.setAccessibilityLabel(L10n.indexSearchLabel.text)
        field.bezelStyle = .roundedBezel
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier(SessionIndexView.searchIdentifier)
        field.delegate = context.coordinator
        field.model = model
        model.leadingPane.searchField = field
        return field
    }

    func updateNSView(_ field: IndexSearchTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.model = model
        field.model = model
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>?
        weak var model: SessionWindow?

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text?.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)): model?.escapeInIndexSearch()
            case #selector(NSResponder.moveDown(_:)): model?.focusFirstIndexRow()
            default: return false
            }
            return true
        }
    }
}

/// A pane that Find in Session Index just showed has its search field now: it takes the focus.
final class IndexSearchTextField: NSTextField {
    weak var model: SessionWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, model?.leadingPane.searchFocusRequest == true else { return }
        model?.focusIndexSearch()
    }
}

/// The kind filter: four segments, the text "All" and the glyphs for Clips, Markers,
/// and Chapters, each with a label and a help tag. Under the width that the segments need, a
/// pull-down menu with the same four choices.
struct IndexKindFilter: View {
    @Binding var kind: SessionIndex.Kind?

    /// The four choices: nil is All. A choice with a symbol shows it in place of its title.
    static let choices: [(kind: SessionIndex.Kind?, title: L10n, symbol: String?)] = [
        (nil, .indexFilterAll, nil), (.clip, .indexFilterClips, IndexTableSource.symbol(.clip)),
        (.marker, .menuMarkers, IndexTableSource.symbol(.marker)),
        (.chapter, .indexFilterChapters, IndexTableSource.symbol(.chapter)),
    ]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            IndexKindSegments(kind: $kind)
            Picker(selection: $kind) {
                ForEach(Self.choices, id: \.title) { Text($0.title.key).tag($0.kind) }
            } label: {
                Text(L10n.indexFilterAll.key)
            }
            .pickerStyle(.menu).labelsHidden()
        }
    }
}

/// The segments as an `NSSegmentedControl`, so each glyph has its accessibility description and
/// its help tag.
private struct IndexKindSegments: NSViewRepresentable {
    @Binding var kind: SessionIndex.Kind?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = IndexKindFilter.choices.count
        control.trackingMode = .selectOne
        control.controlSize = .small
        for (n, choice) in IndexKindFilter.choices.enumerated() {
            let title = choice.title.text
            if let symbol = choice.symbol {
                control.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: title), forSegment: n)
            } else {
                control.setLabel(title, forSegment: n)
            }
            control.setToolTip(title, forSegment: n)
        }
        control.target = context.coordinator
        control.action = #selector(Coordinator.pick(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.kind = $kind
        let selected = IndexKindFilter.choices.firstIndex { $0.kind == kind } ?? 0
        if control.selectedSegment != selected { control.selectedSegment = selected }
    }

    /// The pane asks again at each list update: the segments keep the size of the first measure.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        if context.coordinator.fitting == nil { context.coordinator.fitting = nsView.fittingSize }
        return context.coordinator.fitting
    }

    @MainActor final class Coordinator: NSObject {
        var kind: Binding<SessionIndex.Kind?>?
        var fitting: CGSize?

        @objc func pick(_ control: NSSegmentedControl) {
            kind?.wrappedValue = IndexKindFilter.choices[control.selectedSegment].kind
        }
    }
}
