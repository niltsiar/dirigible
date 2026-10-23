import AppKit
import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The tab of the inspector.
enum InspectorTab: Hashable {
    case clip, episode, marker
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
                ArtworkWell(
                    url: episode.artwork.map { studio.url.appending(path: $0.path) }, identifier: "episode.artwork",
                    label: .episodeArtwork, noneLabel: .episodeArtworkNone, set: model.setArtwork,
                    choose: model.chooseArtwork, remove: model.removeArtwork)
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
                        // An empty cell of 0 x 0 pt, because a cell with no fixed size stops the
                        // fields from filling the width.
                        Color.clear.frame(width: 0, height: 0)
                        Toggle(
                            L10n.episodeExplicit.key,
                            isOn: Binding(get: { episode.explicit }, set: { model.setExplicit($0) })
                        )
                        .accessibilityIdentifier("episode.explicit")
                    }
                }
                ForEach(
                    takeSyncLines(
                        studio.takeMap.map.sync, faults: studio.takeMap.faults.map(\.error),
                        sampleRate: studio.session.sampleRate),
                    id: \.self
                ) { line in
                    Text(verbatim: line).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("episode.takeSync")
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
            // A field under Links shows only when Links is open, so a hold there opens it.
            if [.episodeURL, .feedURL, .guid].contains(field), !linksShown {
                linksShown = true
                await Task.yield()
            }
            focus = field
            model.episodeFocusRequest = nil
        }
    }

    private func header(_ title: L10n) -> some View {
        Text(title.key).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func row(_ name: EpisodeField, _ label: L10n, _ episode: Episode, prompt: L10n? = nil) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            // The column takes the width of its widest label, so no label is cut (C17, C19).
            Text(label.key).foregroundStyle(.secondary).lineLimit(1).fixedSize().gridColumnAlignment(.trailing)
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
                .frame(maxWidth: .infinity)
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

extension SessionWindow {
    /// File > Episode Info…: shows the inspector on the Episode tab with the focus in Title.
    func showEpisodeInfo() {
        if !showsInspector { toggleInspector() }
        inspectorTab = .episode
        episodeFocusRequest = .title
    }

    /// The Clip, Episode, or Marker tab of the inspector. The typed text of the panes is saved
    /// first. A refused episode draft keeps the Episode tab; a refused marker draft goes.
    func selectInspectorTab(_ tab: InspectorTab) {
        if tab != .episode, holdsRefusedEpisode() {
            heldTabChanges += 1
            return
        }
        commitInspector()
        if markerDraft?.refused == true { markerDraft = nil }
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
        edit(ripple: false) { s in s.setEpisode(episode) }
    }

    func setExplicit(_ explicit: Bool) {
        guard var episode = idleStudio?.session.episode, episode.explicit != explicit else { return }
        episode.explicit = explicit
        edit(ripple: false) { s in s.setEpisode(episode) }
    }

    /// Choose… of the artwork.
    func chooseArtwork() { chooseImage(setArtwork) }

    /// Copies the image into the package and sets it as the episode artwork (`importImage`).
    func setArtwork(_ url: URL) {
        importImage { studio throws(StudioError) in try await studio.setArtwork(from: url) }
    }

    /// Remove of the artwork: one edit. The file stays in `Artwork/` for undo and the backups.
    func removeArtwork() {
        guard var episode = idleStudio?.session.episode, episode.artwork != nil else { return }
        episode.artwork = nil
        edit(ripple: false) { s in s.setEpisode(episode) }
    }
}

/// The take sync lines of the Episode inspector (decision 0061), as `dirigible info` gives them:
/// one line for each take with audio, in take order, then one line for each anchor read fault.
/// `text` gives the value of a key.
func takeSyncLines(
    _ sync: [Int: TakeSync], faults: [FinalizeError], sampleRate: Int, locale: Locale = .current,
    text: (L10n) -> String = { $0.text }
) -> [String] {
    let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(3)).grouping(.never)
        .sign(strategy: .always()).rounded(rule: .toNearestOrAwayFromZero).locale(locale)
    return sync.sorted { $0.key < $1.key }.map { take, state in
        switch state {
        case .inSync(let offset):
            String(format: text(.episodeTakeSyncIn), take, (Double(offset) / Double(sampleRate)).formatted(style))
        case .broken(let from, let shifts):
            String(format: text(.episodeTakeSyncBroken), take, takeSyncClock(from, rate: sampleRate), shifts)
        }
    } + faults.map { String(format: text(.episodeTakeSyncFault), $0.fault.file) }
}
