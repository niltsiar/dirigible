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
/// once, so a Cancel of the panel keeps it, and the next export shows it. Nil `defaults`: the
/// default of each value and no writes (tests).
@Observable @MainActor final class ExportSettings {
    enum Format: String, CaseIterable {
        case wav, aac, mp3, flac
    }

    @ObservationIgnored private let defaults: UserDefaults?

    var format: Format { didSet { defaults?.set(format.rawValue, forKey: "export.format") } }
    var bits: BitDepth { didSet { defaults?.set(bits.rawValue, forKey: "export.bits") } }
    var bitRate: BitRate { didSet { defaults?.set(bitRate.rawValue, forKey: "export.bitrate") } }
    var layout: ChannelLayout { didSet { defaults?.set(layout.rawValue, forKey: "export.channels") } }
    var rate: ExportRate { didSet { defaults?.set(Self.name(of: rate), forKey: "export.rate") } }
    /// Nil is Off. It is stored as a token, so Off does not come back as the default.
    var loudness: LoudnessTarget? {
        didSet { defaults?.set(loudness?.rawValue ?? "off", forKey: Self.loudnessKey) }
    }
    /// The loudness strip reads it for its target line (decision 0033).
    nonisolated static let loudnessKey = "export.loudness"

    /// The target of a stored token: nil for `off`; a missing or unknown token gives Podcast.
    nonisolated static func loudness(token: String?) -> LoudnessTarget? {
        token == "off" ? nil : token.flatMap(LoudnessTarget.init) ?? .podcast
    }

    /// The stored options, or the defaults: WAV, 24-bit, 128 kbit/s, stereo, the session rate,
    /// and the podcast loudness target. An unknown loudness token gives the podcast target.
    init(defaults: UserDefaults?) {
        self.defaults = defaults
        format = defaults?.string(forKey: "export.format").flatMap(Format.init) ?? .wav
        bits = BitDepth(rawValue: defaults?.integer(forKey: "export.bits") ?? 0) ?? .bits24
        bitRate = BitRate(rawValue: defaults?.integer(forKey: "export.bitrate") ?? 0) ?? .k128
        layout = defaults?.string(forKey: "export.channels").flatMap(ChannelLayout.init) ?? .stereo
        let rate = defaults?.string(forKey: "export.rate")
        self.rate = ExportRate.allCases.first { Self.name(of: $0) == rate } ?? .session
        loudness = Self.loudness(token: defaults?.string(forKey: Self.loudnessKey))
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
            case .mp3: .mp3(bitRate)
            case .flac: .flac(bits)
            }
        return ExportOptions(
            format: file, layout: layout, rate: rate, loudness: loudness, introTitle: L10n.exportChapterIntro.text)
    }

    var fileExtension: String {
        switch format {
        case .wav: "wav"
        case .aac: "m4a"
        case .mp3: "mp3"
        case .flac: "flac"
        }
    }

    /// The type of the panel: its extension follows a format change (probe P11).
    var contentType: UTType { UTType(filenameExtension: fileExtension) ?? .audio }
}

/// The line of the export panel about the tracks of the source that are not heard (decision
/// 0039): the count, or the silent-file text when no track is heard.
struct ExportNote: Equatable {
    let key: L10n
    /// The unheard tracks of the source.
    let count: Int

    var text: String { key.format(count) }
}

/// Nil when every track of the source is heard. It counts with `Session.unheardCount(in:)`, from
/// the filter of the mix.
func exportNote(_ session: Session, _ source: ExportSource) -> ExportNote? {
    let unheard = session.unheardCount(in: source.tracks)
    guard unheard > 0 else { return nil }
    if session.heardTracks(in: source.tracks).isEmpty {
        return ExportNote(key: .panelExportNoteSilent, count: unheard)
    }
    return ExportNote(key: unheard == 1 ? .panelExportNoteOne : .panelExportNoteMany, count: unheard)
}

/// The save panel of Export with its accessory pop-ups, as a sheet of `window`.
enum ExportPanel {
    /// Calls `done` with the target at OK, or with nil at Cancel. `note` is one line under the
    /// pop-ups; the panel asks nothing more.
    @MainActor static func begin(
        for window: NSWindow, name: String, sessionRate: Int, settings: ExportSettings, note: String?,
        done: @escaping @MainActor (ExportTarget?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [settings.contentType]
        panel.accessoryView = NSHostingView(
            rootView: ExportAccessory(settings: settings, sessionRate: sessionRate, note: note) { [weak panel] type in
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

/// The answer of the save panel of Export Chapters: the JSON file, and the item at its path that
/// the panel confirmed to replace. Nil `confirmed`: nothing was at the path, so the export does not
/// replace a chapter image beside it (code gate item E3).
struct ChaptersTarget {
    let url: URL
    let confirmed: ConfirmedFile?
}

/// The answer of the save panel of Export Transcript: the file, its form, and the transcript number.
struct TranscriptTarget {
    let url: URL
    let format: SubtitleFormat
    let transcript: Int
}

extension ExportPanel {
    /// The save panel of Export Chapters: a JSON file, with `message` when the times start at the
    /// in point. The panel asks before it replaces a file.
    @MainActor static func beginChapters(
        for window: NSWindow, name: String, message: String?, done: @escaping @MainActor (ChaptersTarget?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.json]
        if let message { panel.message = message }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return done(nil) }
                done(ChaptersTarget(url: url, confirmed: ConfirmedFile(at: url)))
            }
        }
    }

    /// The save panel of Export Transcript: a form pop-up (SRT or WebVTT), whose extension the name
    /// follows, and a transcript pop-up when `transcripts` has two or more (it has one or more).
    /// Each panel starts with SRT and the first transcript. The panel asks before it replaces a file.
    @MainActor static func beginTranscript(
        for window: NSWindow, name: String, transcripts: [(id: TranscriptID, name: String)],
        done: @escaping @MainActor (TranscriptTarget?) -> Void
    ) {
        let choice = TranscriptChoice(transcript: transcripts[0].id.number)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [choice.contentType]
        panel.accessoryView = NSHostingView(
            rootView: TranscriptAccessory(choice: choice, transcripts: transcripts) { [weak panel] type in
                panel?.allowedContentTypes = [type]
            })
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return done(nil) }
                done(TranscriptTarget(url: url, format: choice.format, transcript: choice.transcript))
            }
        }
    }
}

/// The values of the pop-ups of the save panel of Export Transcript.
@Observable @MainActor private final class TranscriptChoice {
    var format = SubtitleFormat.srt
    var transcript: Int

    init(transcript: Int) { self.transcript = transcript }

    /// The type of the panel: its extension follows a form change, as in Export (probe P11).
    var contentType: UTType { UTType(filenameExtension: format.pathExtension) ?? .data }
}

private struct TranscriptAccessory: View {
    @Bindable var choice: TranscriptChoice
    let transcripts: [(id: TranscriptID, name: String)]
    let typeChanged: (UTType) -> Void

    var body: some View {
        Form {
            Picker(L10n.panelExportFormat.key, selection: $choice.format) {
                Text(L10n.panelTranscriptFormatSRT.key).tag(SubtitleFormat.srt)
                Text(L10n.panelTranscriptFormatVTT.key).tag(SubtitleFormat.vtt)
            }
            if transcripts.count > 1 {
                Picker(L10n.panelTranscriptChoice.key, selection: $choice.transcript) {
                    ForEach(transcripts, id: \.id) { transcript in
                        Text(verbatim: "\(transcript.id.number). \(transcript.name)").tag(transcript.id.number)
                    }
                }
            }
        }
        .padding()
        .frame(width: 420)
        .onChange(of: choice.format) { typeChanged(choice.contentType) }
    }
}

private struct ExportAccessory: View {
    @Bindable var settings: ExportSettings
    let sessionRate: Int
    let note: String?
    let typeChanged: (UTType) -> Void

    var body: some View {
        Form {
            Picker(L10n.panelExportFormat.key, selection: $settings.format) {
                Text(L10n.panelExportFormatWAV.key).tag(ExportSettings.Format.wav)
                Text(L10n.panelExportFormatAAC.key).tag(ExportSettings.Format.aac)
                Text(L10n.panelExportFormatMP3.key).tag(ExportSettings.Format.mp3)
                Text(L10n.panelExportFormatFLAC.key).tag(ExportSettings.Format.flac)
            }
            if settings.format == .aac || settings.format == .mp3 {
                Picker(L10n.panelExportBitrate.key, selection: $settings.bitRate) {
                    ForEach(BitRate.allCases, id: \.self) { rate in
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
            Picker(L10n.panelExportLoudness.key, selection: $settings.loudness) {
                Text(L10n.panelExportLoudnessOff.key).tag(LoudnessTarget?.none)
                ForEach(LoudnessTarget.allCases, id: \.self) { target in
                    Text(verbatim: name(target)).tag(Optional(target))
                }
            }
            if let note {
                Text(verbatim: note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(width: 420)
        .onChange(of: settings.format) { typeChanged(settings.contentType) }
    }

    /// The preset name with its value for the chosen channels: -16 stereo, -19 mono for Podcast.
    private func name(_ target: LoudnessTarget) -> String {
        let key: L10n =
            switch target {
            case .podcast: .panelExportLoudnessPodcast
            case .speech: .panelExportLoudnessSpeech
            case .ebu: .panelExportLoudnessEBU
            case .atsc: .panelExportLoudnessATSC
            }
        return key.format(Int(target.integrated(for: settings.layout).value))
    }
}
