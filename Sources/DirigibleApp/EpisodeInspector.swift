import AppKit
import DirigibleAudio
import DirigibleCore
import SwiftUI
import UniformTypeIdentifiers

/// The tab of the inspector.
enum InspectorTab: Hashable {
    case clip, episode
}

/// A text field of the Episode pane.
enum EpisodeField: Hashable {
    case title, show, author, season, number, date, language, copyright, summary, notes, episodeURL, feedURL, guid
}

/// The typed text of an episode field that no commit has saved yet, and the text that the field
/// showed before the typing.
struct EpisodeDraft: Equatable {
    let field: EpisodeField
    let shown: String
    var text: String
}

/// The Episode pane of the inspector (decision 0045): the artwork, the fields, the description,
/// the notes, and the links. A separate view, so a key in Notes does not run the clip pane. Return
/// commits a field and gives the focus to the lanes, Tab commits and goes to the next field, a
/// focus loss commits, and Esc puts back the shown text. In Notes, Command-Return commits.
struct EpisodeInspector: View {
    let model: SessionWindow
    let studio: Studio
    @FocusState private var focus: EpisodeField?
    @State private var linksShown = false
    @State private var notesExpanded = false

    var body: some View {
        let episode = studio.session.episode
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header(.episodeArtwork)
                ArtworkWell(url: episode.artwork.map { studio.url.appending(path: $0.path) }, model: model)
                header(.episodeDetails)
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                    row(.title, .episodeTitle, episode)
                    row(.show, .episodeShow, episode)
                    row(.author, .episodeAuthor, episode)
                    row(.season, .episodeSeason, episode)
                    row(.number, .episodeNumber, episode)
                    row(.date, .episodeDate, episode, prompt: .episodeDatePrompt)
                    row(.language, .episodeLanguage, episode, prompt: .episodeLanguagePrompt)
                    row(.copyright, .episodeCopyright, episode)
                    GridRow {
                        Color.clear.frame(width: 64, height: 1)
                        Toggle(
                            L10n.episodeExplicit.key,
                            isOn: Binding(get: { episode.explicit }, set: { model.setExplicit($0) })
                        )
                        .accessibilityIdentifier("episode.explicit")
                    }
                }
                header(.episodeDescription)
                field(.summary, label: .episodeDescription, episode, axis: .vertical).lineLimit(2...4)
                HStack {
                    header(.episodeNotes)
                    Spacer()
                    Button(L10n.episodeNotesExpand.key, systemImage: notesExpanded ? "chevron.up" : "chevron.down") {
                        notesExpanded.toggle()
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
                notesEditor(episode)
                DisclosureGroup(L10n.episodeLinks.key, isExpanded: $linksShown) {
                    Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                        row(.episodeURL, .episodeURL, episode)
                        row(.feedURL, .episodeFeedURL, episode)
                        row(.guid, .episodeGUID, episode)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .controlSize(.small)
        .font(.system(size: 11))
        .disabled(!model.canEdit)
        .onChange(of: focus) { old, new in
            model.episodeFocus = new
            if old != nil { model.commitEpisode() }
        }
        .task(id: model.focusesEpisodeTitle) {
            guard model.focusesEpisodeTitle else { return }
            focus = .title
            model.focusesEpisodeTitle = false
        }
    }

    private func header(_ title: L10n) -> some View {
        Text(title.key).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func row(_ name: EpisodeField, _ label: L10n, _ episode: Episode, prompt: L10n? = nil) -> some View {
        GridRow {
            Text(label.key).foregroundStyle(.secondary).lineLimit(1).frame(width: 64, alignment: .trailing)
            field(name, label: label, episode, prompt: prompt)
        }
    }

    private func field(
        _ name: EpisodeField, label: L10n, _ episode: Episode, prompt: L10n? = nil, axis: Axis = .horizontal
    ) -> some View {
        TextField(text: text(name, episode), prompt: prompt.map { Text($0.key) }, axis: axis) { Text(label.key) }
            .labelsHidden()
            .focused($focus, equals: name)
            .onSubmit {
                model.commitEpisode()
                model.focusLanes()
            }
            .onExitCommand {
                model.episodeDraft = nil
                model.focusLanes()
            }
            .accessibilityIdentifier("episode.\(name)")
    }

    private func notesEditor(_ episode: Episode) -> some View {
        TextEditor(text: text(.notes, episode))
            .font(.system(size: 11))
            .frame(height: notesExpanded ? 320 : 96)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            .focused($focus, equals: .notes)
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                model.commitEpisode()
                model.focusLanes()
                return .handled
            }
            .accessibilityLabel(Text(L10n.episodeNotes.key))
            .accessibilityIdentifier("episode.notes")
    }

    private func text(_ name: EpisodeField, _ episode: Episode) -> Binding<String> {
        let shown = Self.text(name, episode)
        return Binding(
            get: { model.episodeDraft?.field == name ? model.episodeDraft?.text ?? shown : shown },
            set: { model.typeEpisode($0, in: name) })
    }

    /// The text of a field: the stored value, or empty for no value.
    static func text(_ field: EpisodeField, _ episode: Episode) -> String {
        switch field {
        case .title: episode.title?.text ?? ""
        case .show: episode.show?.text ?? ""
        case .author: episode.author?.text ?? ""
        case .season: episode.season?.description ?? ""
        case .number: episode.number?.description ?? ""
        case .date: episode.date?.description ?? ""
        case .language: episode.language?.code ?? ""
        case .copyright: episode.copyright?.text ?? ""
        case .summary: episode.summary?.text ?? ""
        case .notes: episode.notes?.text ?? ""
        case .episodeURL: episode.episodeURL?.text ?? ""
        case .feedURL: episode.feedURL?.text ?? ""
        case .guid: episode.guid?.text ?? ""
        }
    }

    /// Sets `text` on `field` of `episode` through the field type. A blank text clears the field.
    static func set(_ field: EpisodeField, _ text: String, in episode: inout Episode) throws(EpisodeFieldError) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let blank = trimmed.isEmpty
        switch field {
        case .title: episode.title = try EpisodeLine(text)
        case .show: episode.show = try EpisodeLine(text)
        case .author: episode.author = try EpisodeLine(text)
        case .season: episode.season = blank ? nil : try EpisodeNumber(text: trimmed)
        case .number: episode.number = blank ? nil : try EpisodeNumber(text: trimmed)
        case .date: episode.date = blank ? nil : try CalendarDate(trimmed)
        case .language: episode.language = blank ? nil : try LanguageCode(trimmed)
        case .copyright: episode.copyright = try EpisodeLine(text)
        case .summary: episode.summary = try EpisodeNotes(text)
        case .notes: episode.notes = try EpisodeNotes(text)
        case .episodeURL: episode.episodeURL = blank ? nil : try WebURL(trimmed)
        case .feedURL: episode.feedURL = blank ? nil : try WebURL(trimmed)
        case .guid: episode.guid = try EpisodeLine(text)
        }
    }
}

/// The artwork image with Choose… and Remove. It takes a dropped JPEG or PNG file. A separate
/// view, so a key in a field does not read the image again.
private struct ArtworkWell: View {
    let url: URL?
    let model: SessionWindow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let url, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable()
                } else {
                    Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            .accessibilityLabel(Text(url == nil ? L10n.episodeArtworkNone.key : L10n.episodeArtwork.key))
            .dropDestination(for: URL.self) { urls, _ in
                guard let first = urls.first else { return false }
                model.setArtwork(first)
                return true
            }
            VStack(alignment: .leading, spacing: 6) {
                Button(L10n.episodeArtworkChoose.key) { model.chooseArtwork() }
                    .accessibilityIdentifier("episode.artwork.choose")
                Button(L10n.episodeArtworkRemove.key) { model.removeArtwork() }
                    .disabled(url == nil)
                    .accessibilityIdentifier("episode.artwork.remove")
            }
        }
    }
}

extension SessionWindow {
    /// File > Episode Info…: shows the inspector on the Episode tab with the focus in Title.
    func showEpisodeInfo() {
        if !showsInspector { toggleInspector() }
        inspectorTab = .episode
        focusesEpisodeTitle = true
    }

    /// A typed key in an episode field, as `type(_:in:)` of the clip pane: the first key of a
    /// field commits the draft of another field and starts a draft.
    func typeEpisode(_ text: String, in field: EpisodeField) {
        guard showsInspector else { return }
        if episodeDraft?.field == field {
            episodeDraft?.text = text
            return
        }
        guard let studio = idleStudio else { return }
        let shown = EpisodeInspector.text(field, studio.session.episode)
        guard text != shown else { return }
        commitEpisode()
        episodeDraft = EpisodeDraft(field: field, shown: shown, text: text)
    }

    /// Sets the typed text of the draft as one edit. A text that its type refuses beeps. The
    /// draft goes in each case, so the field shows the value again. A busy studio keeps the draft.
    func commitEpisode() {
        guard let draft = episodeDraft, let session = idleStudio?.session else { return }
        episodeDraft = nil
        guard draft.text != draft.shown else { return }
        var episode = session.episode
        do throws(EpisodeFieldError) {
            try EpisodeInspector.set(draft.field, draft.text, in: &episode)
        } catch {
            return beep()
        }
        guard episode != session.episode else { return }
        edit { s in s.setEpisode(episode) }
    }

    func setExplicit(_ explicit: Bool) {
        guard var episode = idleStudio?.session.episode, episode.explicit != explicit else { return }
        episode.explicit = explicit
        edit { s in s.setEpisode(episode) }
    }

    /// Choose… of the artwork: the open panel as a sheet of the window, then the import.
    func chooseArtwork() {
        guard canImport, let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.beginSheetModal(for: window) { [weak self] answer in
            if answer == .OK, let url = panel.url { self?.setArtwork(url) }
        }
    }

    /// Copies the image into the package and sets it, as an import: the banner shows the file
    /// name and Cancel. A refusal shows an alert.
    func setArtwork(_ url: URL) {
        guard canImport, let studio = idleStudio else { return beep() }
        importJob = ImportJob()
        importJob?.task = Task { [weak self] in
            do throws(StudioError) {
                try await studio.setArtwork(from: url)
            } catch .audioImport(.cancelled) {
            } catch {
                self?.alert = .error(error)
            }
            self?.importJob = nil
        }
    }

    /// Remove of the artwork: one edit. The file stays in `Artwork/` for undo and the backups.
    func removeArtwork() {
        guard var episode = idleStudio?.session.episode, episode.artwork != nil else { return }
        episode.artwork = nil
        edit { s in s.setEpisode(episode) }
    }
}
