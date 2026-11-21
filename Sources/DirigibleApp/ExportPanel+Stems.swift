import AppKit
import DirigibleAudio
import DirigibleCore
import SwiftUI

/// Where the stem save panel puts the export: the new folder, and the grouping and options of its
/// pop-ups (decision 0078).
struct StemsTarget {
    let folder: URL
    let grouping: StemGrouping
    let options: StemOptions
}

/// The options of the stem save panel. Each change goes to `defaults` at once, so a Cancel keeps
/// it. A value that the panel never stored starts from the export value (`ExportSettings`). A stem
/// is WAV or FLAC, so an export format of AAC or MP3 starts at WAV. Nil `defaults`: the start
/// values and no writes (tests).
@Observable @MainActor final class StemSettings {
    enum Format: String, CaseIterable {
        case wav, flac
    }

    @ObservationIgnored private let defaults: UserDefaults?

    var grouping: StemGrouping { didSet { defaults?.set(grouping.rawValue, forKey: "stems.by") } }
    var format: Format { didSet { defaults?.set(format.rawValue, forKey: "stems.format") } }
    var bits: BitDepth { didSet { defaults?.set(bits.rawValue, forKey: "stems.bits") } }
    var layout: ChannelLayout { didSet { defaults?.set(layout.rawValue, forKey: "stems.channels") } }
    var rate: ExportRate { didSet { defaults?.set(ExportSettings.name(of: rate), forKey: "stems.rate") } }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        let start = ExportSettings(defaults: defaults)
        grouping = defaults?.string(forKey: "stems.by").flatMap(StemGrouping.init) ?? .track
        format = defaults?.string(forKey: "stems.format").flatMap(Format.init) ?? (start.format == .flac ? .flac : .wav)
        bits = BitDepth(rawValue: defaults?.integer(forKey: "stems.bits") ?? 0) ?? start.bits
        layout = defaults?.string(forKey: "stems.channels").flatMap(ChannelLayout.init) ?? start.layout
        let rate = defaults?.string(forKey: "stems.rate")
        self.rate = ExportRate.allCases.first { ExportSettings.name(of: $0) == rate } ?? start.rate
    }

    var options: StemOptions {
        StemOptions(format: format == .wav ? .wav(bits) : .flac(bits), layout: layout, rate: rate)
    }
}

extension StemTitles {
    /// The role titles of the app language, from `text` (the tables of the app). The titles of the
    /// roles are those of the Role menu, so one word has one key (decision 0010).
    static func app(_ text: (L10n) -> String = { $0.text }) -> StemTitles {
        StemTitles(
            dialogue: text(.trackRoleDialogue), music: text(.trackRoleMusic), effects: text(.trackRoleEffects),
            none: text(.panelStemsRoleNone))
    }
}

/// The text that refuses `name` as a stem folder name, or nil. The limit is the one of the CLI and
/// the tools (`stemFolderNameLimit`, in UTF-8 bytes).
func stemFolderNameProblem(_ name: String) -> String? {
    name.utf8.count <= stemFolderNameLimit ? nil : L10n.panelStemsNameTooLong.format(stemFolderNameLimit)
}

/// The message of the stem save panel: the scope line, then the line of the Export panel that
/// counts the tracks of the source that are not heard (`exportNote`). The scope line says how many
/// tracks of the session the stems cover, and the Marks range or the whole session.
func stemPanelMessage(_ session: Session, _ source: ExportSource) -> String {
    let total = session.tracks.count
    let chosen = source.tracks.map { ids in session.tracks.filter { ids.contains($0.id) }.count } ?? total
    let rate = session.sampleRate
    let scope =
        source.range == .zero..<session.end
        ? L10n.panelStemsScopeWhole.format(chosen, total)
        : L10n.panelStemsScopeRange.format(
            chosen, total, SilenceReview.clock(source.range.lowerBound, rate: rate),
            SilenceReview.clock(source.range.upperBound, rate: rate))
    return [scope, exportNote(session, source)?.text].compactMap { $0 }.joined(separator: "\n")
}

/// Refuses a folder name over the limit with a text, so the panel stays open.
@MainActor private final class StemNameCheck: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, validate url: URL) throws {
        guard let text = stemFolderNameProblem(url.lastPathComponent) else { return }
        throw NSError(domain: "Dirigible.StemPanel", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

extension ExportPanel {
    /// The save panel of a stem export: it names a new folder, so its label says Folder name and
    /// its button says Export.
    @MainActor static func stemsPanel(name: String, message: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.nameFieldLabel = L10n.panelStemsFolderName.text
        panel.prompt = L10n.alertExportConfirm.text
        panel.message = message
        panel.canCreateDirectories = true
        return panel
    }

    /// Calls `done` with the folder and the options at OK, or with nil at Cancel.
    @MainActor static func beginStems(
        for window: NSWindow, name: String, sessionRate: Int, settings: StemSettings, message: String,
        done: @escaping @MainActor (StemsTarget?) -> Void
    ) {
        let panel = stemsPanel(name: name, message: message)
        let check = StemNameCheck()
        panel.delegate = check
        panel.accessoryView = NSHostingView(rootView: StemAccessory(settings: settings, sessionRate: sessionRate))
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                // The panel holds its delegate weakly: the closure keeps it until the panel ends.
                withExtendedLifetime(check) {
                    guard response == .OK, let url = panel.url else { return done(nil) }
                    done(StemsTarget(folder: url, grouping: settings.grouping, options: settings.options))
                }
            }
        }
    }
}

struct StemAccessory: View {
    @Bindable var settings: StemSettings
    let sessionRate: Int

    var body: some View {
        Form {
            Picker(L10n.panelStemsGroup.key, selection: $settings.grouping) {
                Text(L10n.panelStemsGroupTrack.key).tag(StemGrouping.track)
                Text(L10n.panelStemsGroupRole.key).tag(StemGrouping.role)
            }
            Picker(L10n.panelExportFormat.key, selection: $settings.format) {
                Text(L10n.panelExportFormatWAV.key).tag(StemSettings.Format.wav)
                Text(L10n.panelExportFormatFLAC.key).tag(StemSettings.Format.flac)
            }
            ExportFormatPickers(
                bits: $settings.bits, layout: $settings.layout, rate: $settings.rate, sessionRate: sessionRate)
            Text(L10n.panelStemsContent.key).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 420)
    }
}
