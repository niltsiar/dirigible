import AppKit
import DirigibleAudio
import DirigibleCore
import SwiftUI

/// A field of the Marker pane.
enum MarkerField: Hashable {
    case name, url
}

/// The typed text of a marker field that no commit has saved yet, the text that the field showed
/// before the typing, and the marker of the first key. A commit sets this marker, also after the
/// current marker changes (C9).
struct MarkerDraft: Equatable {
    let marker: MarkerID
    let field: MarkerField
    let shown: String
    var text: String
    /// True after a commit that the field rule refused. The pane shows the rule.
    var refused = false
}

/// The Marker pane of the inspector (run 2026-10-11-chapters-in-file, C9): the name and the time
/// of the current marker, Name, Link, and the image well. Only a chapter has a link and an image.
/// Return commits a field and gives the focus to the lanes, Tab commits and goes to the next
/// field, a focus loss commits, and Esc puts back the shown text.
struct MarkerInspector: View {
    let model: SessionWindow
    let studio: Studio
    @FocusState private var focus: MarkerField?

    var body: some View {
        // One container carries the modifiers: a switch between its branches is no pane leaving.
        ZStack {
            Group {
                if let id = model.timeline.marker, let marker = studio.session.markers[id] {
                    pane(marker)
                } else {
                    // The style of No Selection of the Clip pane.
                    Text(L10n.markerNone.key).font(.title3).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        // A field with the focus ends its edit at a marker change, so it never shows the text of
        // the marker before. The focus change commits.
        .onChange(of: model.timeline.marker) { focus = nil }
        .onChange(of: focus) { old, new in
            model.markerFocus = new
            if old != nil { model.commitMarker() }
            guard let field = model.markerFocusRequest else { return }
            if new == nil {
                focus = field
            } else if new != field || model.fieldEditorHasFocus {
                model.markerFocusRequest = nil
            }
        }
        .task(id: model.markerFocusRequest) { giveFocus() }
        .onDisappear { model.markerFocusRequest = nil }
    }

    /// Sets the focus to the field of the request. A focus value that already equals it ends the
    /// request only while a field editor is first responder; else the value is stale, and the nil
    /// report of SwiftUI sets the field again.
    private func giveFocus() {
        guard let field = model.markerFocusRequest else { return }
        if focus != field {
            focus = field
        } else if model.fieldEditorHasFocus {
            model.markerFocusRequest = nil
        }
    }

    private func pane(_ marker: Marker) -> some View {
        let chapter = marker.kind == .chapter
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // The header style of the Clip and Episode panes.
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: marker.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(verbatim: timeDisplayText(marker.position, rate: studio.session.sampleRate, playing: false))
                        .monospacedDigit()
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                    row(.name, .markerName, marker)
                    row(.url, .markerURL, marker).disabled(!chapter)
                }
                if !chapter {
                    Text(L10n.markerChapterOnly.key).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.markerImage.key).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ArtworkWell(
                    url: marker.image.map { studio.url.appending(path: $0.path) }, identifier: "marker.image",
                    label: .markerImage, noneLabel: .markerImageNone, set: model.setMarkerImage,
                    choose: model.chooseMarkerImage, remove: model.removeMarkerImage
                )
                .disabled(!chapter)
            }
        }
        .controlSize(.small)
        .font(.system(size: 11))
        .disabled(!model.canEdit)
    }

    private func row(_ field: MarkerField, _ label: L10n, _ marker: Marker) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label.key).foregroundStyle(.secondary).lineLimit(1).fixedSize().gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 2) {
                TextField(
                    text: text(field, marker), prompt: field == .url ? Text(verbatim: "https://") : nil
                ) { Text(label.key) }
                .labelsHidden()
                .focused($focus, equals: field)
                .onAppear { giveFocus() }
                .onSubmit {
                    model.commitMarker()
                    if model.markerDraft?.refused != true { model.focusLanes() }
                }
                .onExitCommand {
                    model.markerDraft = nil
                    model.focusLanes()
                }
                .accessibilityIdentifier(field == .name ? "marker.name" : "marker.url")
                .frame(maxWidth: .infinity)
                if let draft = model.markerDraft, draft.marker == marker.id, draft.field == field, draft.refused {
                    let rule = Self.refusal(field)
                    Text(rule == .errorMarkerURL ? rule.format(Marker.maximumURLBytes) : rule.text)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("marker.refusal")
                }
            }
        }
    }

    /// The key of the rule of a field: Name takes one line, Link an http or https URL.
    static func refusal(_ field: MarkerField) -> L10n {
        field == .url ? .errorMarkerURL : .errorEpisodeLine
    }

    /// The field shows the draft of its own marker, else the stored text. The field passes its
    /// marker with each key, so an old text that it sends after a marker change stays with that
    /// marker.
    private func text(_ field: MarkerField, _ marker: Marker) -> Binding<String> {
        let shown = marker.text(of: field)
        return Binding(
            get: {
                guard let draft = model.markerDraft, draft.marker == marker.id, draft.field == field,
                    draft.refused || draft.shown == shown
                else { return shown }
                return draft.text
            },
            set: { model.typeMarker($0, in: field, of: marker.id) })
    }
}

extension Marker {
    func text(of field: MarkerField) -> String {
        field == .name ? name : url?.text ?? ""
    }

    /// Sets `text` on `field` with the rule of `Session.setMarker`; false when the rule refuses it.
    /// An empty Link clears the link.
    mutating func set(_ field: MarkerField, text: String) -> Bool {
        switch field {
        case .name:
            guard text.unicodeScalars.allSatisfy(\.isStorableInSession) else { return false }
            name = text
        case .url:
            do { url = try Marker.url(fromText: text) } catch { return false }
        }
        return true
    }
}

extension SessionWindow {
    /// Markers > Marker Info… and a double-click on a flag: the inspector on the Marker tab with
    /// the focus in Name. With no current marker it beeps, and the pane shows No Marker. During a
    /// take it does nothing, as the other marker commands (decision 0018).
    func showMarkerInfo() {
        guard canEdit else { return }
        let marker = timeline.marker.flatMap { studio?.session.markers[$0] }
        if marker == nil { beep() }
        if !showsInspector { toggleInspector() }
        selectInspectorTab(.marker)
        if marker != nil, inspectorTab == .marker { markerFocusRequest = .name }
    }

    /// A typed key in a field of the pane of `marker`. The first key commits a draft of another
    /// field or marker and starts a draft. A plain marker takes no link.
    func typeMarker(_ text: String, in field: MarkerField, of marker: MarkerID) {
        guard showsInspector else { return }
        if let draft = markerDraft, draft.marker == marker, draft.field == field {
            // A field that gets the focus sends its text again: only a changed text ends a refusal.
            guard text != draft.text else { return }
            markerDraft?.text = text
            markerDraft?.refused = false
            return
        }
        guard let stored = idleStudio?.session.markers[marker], field == .name || stored.kind == .chapter else {
            return
        }
        let shown = stored.text(of: field)
        guard text != shown else { return }
        commitMarker()
        markerDraft = MarkerDraft(marker: marker, field: field, shown: shown, text: text)
    }

    /// Sets the typed text of the draft on its marker as one edit. A text that the rule refuses
    /// beeps once and keeps the draft, and the pane shows the rule. A busy studio keeps the draft.
    /// A draft whose stored value changed after its first key (an undo, an MCP edit) goes.
    func commitMarker() {
        guard let draft = markerDraft, !draft.refused, let session = idleStudio?.session else { return }
        guard var marker = session.markers[draft.marker], marker.text(of: draft.field) == draft.shown else {
            markerDraft = nil
            return
        }
        guard marker.set(draft.field, text: draft.text) else {
            markerDraft?.refused = true
            return beep()
        }
        markerDraft = nil
        guard marker != session.markers[draft.marker] else { return }
        edit(ripple: false) { s throws(SessionError) in try s.setMarker(marker) }
    }

    /// Choose… of the chapter image.
    func chooseMarkerImage() { chooseImage(setMarkerImage) }

    /// Copies the image into the package and sets it on the current chapter (`importImage`). A
    /// plain marker takes no image: a beep.
    func setMarkerImage(_ url: URL) {
        guard let id = timeline.marker, studio?.session.markers[id]?.kind == .chapter else { return beep() }
        importImage { studio throws(StudioError) in try await studio.setMarkerImage(id, from: url) }
    }

    /// Remove of the chapter image: one edit. The file stays in `Artwork/` for undo and the backups.
    func removeMarkerImage() {
        guard let id = timeline.marker, var marker = idleStudio?.session.markers[id], marker.image != nil else {
            return
        }
        marker.image = nil
        edit(ripple: false) { s throws(SessionError) in try s.setMarker(marker) }
    }
}
