import AppKit
import DirigibleAudio
import DirigibleCore
import SwiftUI
import UniformTypeIdentifiers

/// Where the save panel puts the export: the file, the options, and the item that the user
/// confirmed to replace (the panel asked "replace?"). Nil `confirmed`: nothing was at the path.
struct ExportTarget {
    let url: URL
    let options: ExportOptions
    let confirmed: ConfirmedFile?
}

/// The options of the save panel pop-ups (decision 0019). Each change goes to `defaults` at
/// once, so a Cancel of the panel keeps it, and the next export shows it.
@Observable @MainActor final class ExportSettings {
    enum Format: String, CaseIterable {
        case wav, aac, flac
    }

    @ObservationIgnored private let defaults: UserDefaults

    var format: Format { didSet { defaults.set(format.rawValue, forKey: "export.format") } }
    var bits: BitDepth { didSet { defaults.set(bits.rawValue, forKey: "export.bits") } }
    var bitRate: AACBitRate { didSet { defaults.set(bitRate.rawValue, forKey: "export.bitrate") } }
    var layout: ChannelLayout { didSet { defaults.set(layout.rawValue, forKey: "export.channels") } }
    var rate: ExportRate { didSet { defaults.set(Self.name(of: rate), forKey: "export.rate") } }

    /// The stored options, or the defaults: WAV, 24-bit, 128 kbit/s, stereo, the session rate.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        format = defaults.string(forKey: "export.format").flatMap(Format.init) ?? .wav
        bits = BitDepth(rawValue: defaults.integer(forKey: "export.bits")) ?? .bits24
        bitRate = AACBitRate(rawValue: defaults.integer(forKey: "export.bitrate")) ?? .k128
        layout = defaults.string(forKey: "export.channels").flatMap(ChannelLayout.init) ?? .stereo
        let rate = defaults.string(forKey: "export.rate")
        self.rate = ExportRate.allCases.first { Self.name(of: $0) == rate } ?? .session
    }

    private static func name(of rate: ExportRate) -> String {
        switch rate {
        case .session: "session"
        case .hz44100: "44100"
        case .hz48000: "48000"
        }
    }

    var options: ExportOptions {
        let file: ExportFormat =
            switch format {
            case .wav: .wav(bits)
            case .aac: .aac(bitRate)
            case .flac: .flac(bits)
            }
        return ExportOptions(format: file, layout: layout, rate: rate)
    }

    var fileExtension: String {
        switch format {
        case .wav: "wav"
        case .aac: "m4a"
        case .flac: "flac"
        }
    }

    /// The type of the panel: its extension follows a format change (probe P11).
    var contentType: UTType { UTType(filenameExtension: fileExtension) ?? .audio }
}

/// The save panel of Export with its accessory pop-ups, as a sheet of `window`.
enum ExportPanel {
    /// Calls `done` with the target at OK, or with nil at Cancel.
    @MainActor static func begin(
        for window: NSWindow, name: String, sessionRate: Int, settings: ExportSettings,
        done: @escaping @MainActor (ExportTarget?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [settings.contentType]
        panel.accessoryView = NSHostingView(
            rootView: ExportAccessory(settings: settings, sessionRate: sessionRate) { [weak panel] type in
                panel?.allowedContentTypes = [type]
            })
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return done(nil) }
                done(ExportTarget(url: url, options: settings.options, confirmed: ConfirmedFile(at: url)))
            }
        }
    }
}

private struct ExportAccessory: View {
    @Bindable var settings: ExportSettings
    let sessionRate: Int
    let typeChanged: (UTType) -> Void

    var body: some View {
        Form {
            Picker(L10n.panelExportFormat.key, selection: $settings.format) {
                Text(L10n.panelExportFormatWAV.key).tag(ExportSettings.Format.wav)
                Text(L10n.panelExportFormatAAC.key).tag(ExportSettings.Format.aac)
                Text(L10n.panelExportFormatFLAC.key).tag(ExportSettings.Format.flac)
            }
            if settings.format == .aac {
                Picker(L10n.panelExportBitrate.key, selection: $settings.bitRate) {
                    ForEach(AACBitRate.allCases, id: \.self) { rate in
                        Text(verbatim: L10n.panelExportBitrateValue.format(rate.rawValue)).tag(rate)
                    }
                }
            } else {
                Picker(L10n.panelExportBits.key, selection: $settings.bits) {
                    ForEach(BitDepth.allCases, id: \.self) { bits in Text(verbatim: "\(bits.rawValue)").tag(bits) }
                }
            }
            Picker(L10n.panelExportChannels.key, selection: $settings.layout) {
                Text(L10n.panelExportChannelsStereo.key).tag(ChannelLayout.stereo)
                Text(L10n.panelExportChannelsMono.key).tag(ChannelLayout.mono)
            }
            Picker(L10n.panelExportRate.key, selection: $settings.rate) {
                Text(verbatim: L10n.panelExportRateSession.format(sessionRate)).tag(ExportRate.session)
                Text(L10n.panelExportRate44100.key).tag(ExportRate.hz44100)
                Text(L10n.panelExportRate48000.key).tag(ExportRate.hz48000)
            }
        }
        .padding()
        .frame(width: 320)
        .onChange(of: settings.format) { typeChanged(settings.contentType) }
    }
}
