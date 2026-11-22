import AppKit
import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The Bins segment of the leading pane (F22): the list of the bins and their items, and New Bin. A
/// session with no bin shows "No Bins" with a New Bin button (C31). The body reads the bins and the
/// media faults of the studio, not the playhead.
struct BinsSegment: View {
    let model: SessionWindow
    let studio: Studio

    var body: some View {
        let bins = studio.session.bins
        VStack(spacing: 8) {
            if bins.isEmpty {
                ContentUnavailableView {
                    Text(L10n.binsEmpty.key)
                } description: {
                    Text(L10n.binsEmptyHint.key)
                } actions: {
                    Button(L10n.binsNew.key) { model.newBin() }.disabled(!model.canEdit)
                }
            } else {
                BinsTable(
                    model: model, rows: BinsRow.rows(bins, faults: studio.missingMedia),
                    rate: studio.session.sampleRate)
                HStack {
                    Button(L10n.binsNew.key) { model.newBin() }.disabled(!model.canEdit)
                    Spacer()
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The leading pane: the switch "Index" and "Bins" at the top, then only the shown segment (C19).
struct LeadingPane: View {
    let model: SessionWindow
    let studio: Studio

    var body: some View {
        VStack(spacing: 0) {
            Picker(
                selection: Binding(get: { model.leadingPane.segment }, set: { model.selectSegment($0) })
            ) {
                Text(L10n.indexSegmentIndex.key).tag(PaneSegment.index)
                Text(L10n.indexSegmentBins.key).tag(PaneSegment.bins)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 8)
            switch model.leadingPane.segment {
            case .index: SessionIndexView(model: model, studio: studio)
            case .bins: BinsSegment(model: model, studio: studio)
            }
        }
    }
}
