import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The Bit depth, Channels, and Sample rate pop-ups of an export panel: the mix panel and the stem
/// panel list the same values. A lossy mix has a bit rate in place of the bit depth (`showsBits`).
struct ExportFormatPickers: View {
    @Binding var bits: BitDepth
    @Binding var layout: ChannelLayout
    @Binding var rate: ExportRate
    let sessionRate: Int
    var showsBits = true
    /// Each label ends in a colon, as the labels of a save panel do.
    var colons = false

    private func label(_ title: L10n) -> Text { Text(verbatim: colons ? title.text + ":" : title.text) }

    var body: some View {
        if showsBits {
            Picker(selection: $bits) {
                ForEach(BitDepth.allCases, id: \.self) { bits in Text(verbatim: "\(bits.rawValue)").tag(bits) }
            } label: {
                label(.panelExportBits)
            }
        }
        Picker(selection: $layout) {
            Text(L10n.panelExportChannelsStereo.key).tag(ChannelLayout.stereo)
            Text(L10n.panelExportChannelsMono.key).tag(ChannelLayout.mono)
        } label: {
            label(.panelExportChannels)
        }
        Picker(selection: $rate) {
            Text(verbatim: L10n.panelExportRateSession.format(sessionRate)).tag(ExportRate.session)
            Text(L10n.panelExportRate44100.key).tag(ExportRate.hz44100)
            Text(L10n.panelExportRate48000.key).tag(ExportRate.hz48000)
        } label: {
            label(.panelExportRate)
        }
    }
}
