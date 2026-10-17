import AppKit
import DirigibleCore
import SwiftUI

/// The items of the record-over chip (decisions 0016, 0017).
enum RecordOverAction: Equatable {
    case goToEnd, showClip
    case turnOffRecord(TrackID)
}

/// The record-over warning as a chip in the ruler band over the track headers. The lanes do not
/// move, and no ruler time is under it. It is a pull-down menu: the detail text, Go to End, Show
/// Clip, and Turn Off Record for each track of the warning. It reads only the warning that the
/// chrome loop writes on a change and the header width, so a play tick runs no body of it.
struct RecordOverChip: View {
    /// The space between the chip and the edge of the header corner, in points.
    static let inset = 4.0

    /// The warning symbol: a systemOrange triangle with a black mark. A pull-down button draws a
    /// template image in the label color and ignores `foregroundStyle`, so the colors are in the image.
    private static let symbol: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(.init(paletteColors: [.black, .systemOrange]))
        return NSImage(systemSymbolName: WindowBanner.Kind.warning.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
    }()

    let model: SessionWindow

    var body: some View {
        let _ = model.countBody()
        let warning = model.shown.recordOver
        if !warning.isEmpty {
            let _ = model.countOverlay()
            Menu {
                Button(warning.detail) {}.disabled(true)
                Divider()
                Button(L10n.menuTransportEnd.key) { model.recordOver(.goToEnd) }
                Button(L10n.recordOverShow.key) { model.recordOver(.showClip) }
                ForEach(warning.reached, id: \.track) { reached in
                    Button(L10n.recordOverDisarm.format(reached.name)) {
                        model.recordOver(.turnOffRecord(reached.track))
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(nsImage: Self.symbol)
                    Text(L10n.recordOverChip.key).foregroundStyle(.primary).lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .systemOrange).opacity(0.12), in: .rect(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help(Text(verbatim: warning.detail))
            .accessibilityLabel(Text(verbatim: warning.detail))
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 2)
            .frame(width: model.headerWidth.points, height: TimelineRuler.thickness)
        }
    }
}
