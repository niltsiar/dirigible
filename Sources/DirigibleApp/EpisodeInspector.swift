import AppKit
import DirigibleAudio
import DirigibleCore
import SwiftUI
import UniformTypeIdentifiers

/// The tab of the inspector.
enum InspectorTab: Hashable {
    case clip, episode
}

/// The typed text of an episode field that no commit has saved yet, and the text that the field
/// showed before the typing.
struct EpisodeDraft: Equatable {
    let field: EpisodeField
    let shown: String
    var text: String
    /// True after a commit that the field type refused. The pane shows the rule of the field.
    var refused = false
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
            // A move into another field (also from the lanes) keeps a refused draft; a move out of
            // the pane only commits.
            if let new, new != model.episodeDraft?.field {
                _ = model.holdsRefusedEpisode()
            } else if old != nil {
                model.commitEpisode()
            }
        }
        .task(id: model.episodeFocusRequest) {
            guard let field = model.episodeFocusRequest else { return }
            focus = field
            model.episodeFocusRequest = nil
        }
    }

    private func header(_ title: L10n) -> some View {
        Text(title.key).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func row(_ name: EpisodeField, _ label: L10n, _ episode: Episode, prompt: L10n? = nil) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label.key).foregroundStyle(.secondary).lineLimit(1).frame(width: 64, alignment: .trailing)
            field(name, label: label, episode, prompt: prompt)
        }
    }

    private func field(
        _ name: EpisodeField, label: L10n, _ episode: Episode, prompt: L10n? = nil, axis: Axis = .horizontal
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(text: text(name, episode), prompt: prompt.map { Text($0.key) }, axis: axis) { Text(label.key) }
                .labelsHidden()
                .focused($focus, equals: name)
                .onSubmit {
                    if !model.holdsRefusedEpisode() { model.focusLanes() }
                }
                .onExitCommand {
                    model.episodeDraft = nil
                    model.focusLanes()
                }
                .accessibilityIdentifier("episode.\(name)")
            refusalText(name)
        }
    }

    /// The rule of the field after a refused commit (code gate 1 item 2). Library code has no UI
    /// text (decision 0010), so the pane maps the field to a key.
    @ViewBuilder private func refusalText(_ name: EpisodeField) -> some View {
        if let draft = model.episodeDraft, draft.field == name, draft.refused, let key = Self.refusal(name) {
            Text(key == .errorEpisodeNumber ? key.format(EpisodeNumber.maximum) : key.text)
                .font(.system(size: 11)).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("episode.refusal")
        }
    }

    /// The key of the rule of a field. Nil for Summary and Notes: they refuse no text.
    static func refusal(_ field: EpisodeField) -> L10n? {
        switch field {
        case .title, .show, .author, .copyright, .guid: .errorEpisodeLine
        case .season, .number: .errorEpisodeNumber
        case .date: .errorEpisodeDate
        case .language: .errorEpisodeLanguage
        case .episodeURL, .feedURL: .errorEpisodeURL
        case .summary, .notes: nil
        }
    }

    private func notesEditor(_ episode: Episode) -> some View {
        TextEditor(text: text(.notes, episode))
            .font(.system(size: 11))
            .frame(height: notesExpanded ? 320 : 96)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            .focused($focus, equals: .notes)
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                if !model.holdsRefusedEpisode() { model.focusLanes() }
                return .handled
            }
            .accessibilityLabel(Text(L10n.episodeNotes.key))
            .accessibilityIdentifier("episode.notes")
    }

    private func text(_ name: EpisodeField, _ episode: Episode) -> Binding<String> {
        let shown = episode.text(of: name)
        return Binding(
            get: {
                guard let draft = model.episodeDraft, draft.field == name, draft.refused || draft.shown == shown
                else { return shown }
                return draft.text
            },
            set: { model.typeEpisode($0, in: name) })
    }
}

/// The artwork image with Choose… and Remove. It takes a dropped JPEG or PNG file. A separate
/// view, so a key in a field does not read the image again.
private struct ArtworkWell: View {
    let url: URL?
    let model: SessionWindow
    /// The image of `url`, read once for each path and not at each body pass.
    @State private var image: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if url != nil, let image {
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
            .task(id: url) { image = url.flatMap { NSImage(contentsOf: $0) } }
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
        episodeFocusRequest = .title
    }

    /// The Clip or Episode tab of the inspector. The typed text of both panes is saved first. A
    /// refused episode draft keeps the Episode tab.
    func selectInspectorTab(_ tab: InspectorTab) {
        if tab != .episode, holdsRefusedEpisode() {
            heldTabChanges += 1
            return
        }
        commitInspector()
        inspectorTab = tab
    }

    /// The end rule of a refused draft, as an AppKit formatter that keeps the focus. The draft
    /// commits; a refused draft holds until the user corrects it or presses Esc. Then the pane
    /// shows the Episode tab, the focus goes back to the field, and a draft that was refused
    /// before beeps (`commitEpisode` beeps for a new refusal). Another field, the Clip tab, Hide
    /// Inspector, Close, and Quit call it, and stop when it gives true. A disabled pane (a take
    /// or a blocking run) cannot take a correction, so there the refused draft goes and nothing
    /// stops: Stop and Close and Stop and Quit always go on.
    func holdsRefusedEpisode() -> Bool {
        let wasRefused = episodeDraft?.refused == true
        commitEpisode()
        guard let draft = episodeDraft, draft.refused else { return false }
        guard canEdit else {
            episodeDraft = nil
            return false
        }
        if wasRefused { beep() }
        if !showsInspector { toggleInspector() }
        inspectorTab = .episode
        episodeFocusRequest = draft.field
        return true
    }

    /// A typed key in an episode field, as `type(_:in:)` of the clip pane: the first key of a
    /// field commits the draft of another field and starts a draft. A refused draft of another
    /// field holds, and the key goes.
    func typeEpisode(_ text: String, in field: EpisodeField) {
        guard showsInspector else { return }
        // A draft whose stored value changed (an undo, an MCP edit) gives way, unless refused.
        if let draft = episodeDraft, draft.field == field,
            draft.refused || studio?.session.episode.text(of: field) == draft.shown
        {
            // A field that gets the focus sends its text again: only a changed text ends a refusal.
            guard text != draft.text else { return }
            episodeDraft?.text = text
            episodeDraft?.refused = false
            return
        }
        guard let studio = idleStudio else { return }
        let shown = studio.session.episode.text(of: field)
        guard text != shown, !holdsRefusedEpisode() else { return }
        episodeDraft = EpisodeDraft(field: field, shown: shown, text: text)
    }

    /// Sets the typed text of the draft as one edit. A text that its type refuses beeps once and
    /// keeps the draft, and the pane shows the rule of the field. A later commit of the refused
    /// draft does nothing: play, zoom, and a lane click do not beep. A busy studio keeps the draft.
    /// A draft whose stored value changed after its first key (an undo, an MCP edit) goes.
    func commitEpisode() {
        guard let draft = episodeDraft, !draft.refused, let session = idleStudio?.session else { return }
        guard session.episode.text(of: draft.field) == draft.shown else {
            episodeDraft = nil
            return
        }
        var episode = session.episode
        do throws(EpisodeFieldError) {
            try episode.set(draft.field, text: draft.text)
        } catch {
            episodeDraft?.refused = true
            return beep()
        }
        episodeDraft = nil
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
