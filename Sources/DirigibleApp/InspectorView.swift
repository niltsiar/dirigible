import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline
import SwiftUI

/// A field of the clip inspector.
enum InspectorField: Hashable {
    case gain, fadeIn, fadeOut
}

/// The typed text of an inspector field that no commit has saved yet, the text that the field
/// showed before the typing, and the clips of the inspection at the first key. A commit sets
/// these clips, also after the Marks change (plan gate I2).
struct InspectorDraft: Equatable {
    let field: InspectorField
    let shown: String
    var text: String
    let clips: [ClipID]
}

/// The clip inspector (run 11b-2): Gain, Fade In, and Fade Out of the clips that the selection
/// touches, with Mixed for different values. A fixed width at the trailing edge of the window.
/// Return commits and gives the focus to the lanes, Tab commits and goes to the next field, a
/// focus loss commits, and Esc puts back the shown text.
struct InspectorView: View {
    /// The width of the pane with its divider.
    static let width = 270.0

    let model: SessionWindow
    let studio: Studio
    @FocusState private var focus: InspectorField?

    var body: some View {
        let _ = model.countInspector()
        let inspection = ClipInspection(selection: model.timeline.selection, session: studio.session)
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: Self.title(inspection)).font(.headline).lineLimit(1).truncationMode(.middle)
            Divider()
            if let inspection {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    row(.gain, L10n.inspectorGain, L10n.inspectorDecibels, inspection)
                    row(.fadeIn, L10n.inspectorFadeIn, L10n.inspectorMilliseconds, inspection)
                    row(.fadeOut, L10n.inspectorFadeOut, L10n.inspectorMilliseconds, inspection)
                }
                .disabled(!model.canEdit)
                Spacer()
            } else {
                Spacer()
                Text(L10n.inspectorNone.key).font(.title3).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: focus) { old, new in
            model.inspectorFocus = new
            if old != nil { model.commitInspector() }
        }
    }

    private func row(_ field: InspectorField, _ label: L10n, _ unit: L10n, _ inspection: ClipInspection)
        -> some View
    {
        let shown = Self.text(field, inspection, rate: studio.session.sampleRate)
        let mixed = shown.isEmpty
        let text = Binding(
            get: { model.inspectorDraft?.field == field ? model.inspectorDraft?.text ?? shown : shown },
            set: { model.type($0, in: field) })
        return GridRow {
            Text(label.key).gridColumnAlignment(.trailing)
            HStack(spacing: 4) {
                TextField(text: text, prompt: mixed ? Text(L10n.inspectorMixed.key) : nil) { Text(label.key) }
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                    .focused($focus, equals: field)
                    .onSubmit {
                        model.commitInspector()
                        model.focusLanes()
                    }
                    .onExitCommand {
                        model.inspectorDraft = nil
                        model.focusLanes()
                    }
                    .accessibilityLabel(Text(label.key) + Text(verbatim: ", ") + Text(unit.key))
                Text(unit.key).foregroundStyle(.secondary)
            }
            .gridColumnAlignment(.leading)
        }
    }

    /// The header: the clip name for one clip, "Clips: N" for many, and "Clip" with no clip.
    static func title(_ inspection: ClipInspection?) -> String {
        guard let inspection else { return L10n.inspectorClip.text }
        return inspection.name ?? L10n.inspectorClips.format(inspection.clips.count)
    }

    /// The text of a field: the gain to 0.1 dB, or the fade in whole ms with no grouping, so the
    /// text parses again. Empty for Mixed.
    static func text(_ field: InspectorField, _ inspection: ClipInspection, rate: Int) -> String {
        let fade: ClipInspection.Shown<Frames>
        switch field {
        case .gain:
            guard case .value(let gain) = inspection.gain else { return "" }
            return ReadoutLayer.decibels(gain, locale: .current)
        case .fadeIn: fade = inspection.fadeIn
        case .fadeOut: fade = inspection.fadeOut
        }
        guard case .value(let frames) = fade else { return "" }
        let ms = (Double(frames.count) * 1000 / Double(rate)).rounded()
        return ms.formatted(.number.precision(.fractionLength(0)).grouping(.never).locale(.current))
    }
}

extension SessionWindow {
    /// The app preference of View > Show Inspector: a `Bool`, default false. It never changes its
    /// meaning or type (0024 P11).
    static let inspectorKey = "view.inspector.shown"

    /// View > Show/Hide Inspector. A new window takes the preference. A hide commits the typed
    /// text first, and moves a focus in the pane to the lanes. A show widens a window that is
    /// narrower than the minimum, with no animation.
    func toggleInspector() {
        showsInspector.toggle()
        app?.defaults?.set(showsInspector, forKey: Self.inspectorKey)
        if showsInspector {
            widenForInspector()
            return
        }
        // After the flag: the focus move makes the field send its old text, which `type` ignores.
        commitInspector()
        if inspectorFocus != nil {
            inspectorFocus = nil
            focusLanes()
        }
    }

    /// A typed key in an inspector field. The first key of a field commits the draft of another
    /// field and starts a draft with the clips of the inspection. The field also sends its text
    /// when it shows a new value or ends its editing; a text equal to the shown text is not a key,
    /// so it starts no draft. A field that a hide removes sends its old text: a hidden pane takes
    /// no text, else a later commit sets that old value again.
    func type(_ text: String, in field: InspectorField) {
        guard showsInspector else { return }
        if inspectorDraft?.field == field {
            inspectorDraft?.text = text
            return
        }
        guard let studio = idleStudio,
            let inspection = ClipInspection(selection: timeline.selection, session: studio.session)
        else { return }
        let shown = InspectorView.text(field, inspection, rate: studio.session.sampleRate)
        guard text != shown else { return }
        commitInspector()
        inspectorDraft = InspectorDraft(field: field, shown: shown, text: text, clips: inspection.clips)
    }

    /// Sets the typed value on the clips of the draft as one edit. A text equal to the shown text,
    /// or empty, makes no edit. A text that does not parse beeps. The draft goes in each case, so
    /// the field shows the value again. A busy studio keeps the draft for a later commit.
    func commitInspector() {
        guard let draft = inspectorDraft, let session = idleStudio?.session else { return }
        inspectorDraft = nil
        let text = draft.text.trimmingCharacters(in: .whitespaces)
        guard text != draft.shown, !text.isEmpty else { return }
        switch draft.field {
        case .gain:
            guard let dB = ClipInspection.decibels(text) else { return beep() }
            guard let gains = ClipInspection.gains(dB, for: draft.clips, in: session) else { return }
            edit { s throws(SessionError) in try s.setGains(gains) }
        case .fadeIn, .fadeOut:
            guard let ms = ClipInspection.milliseconds(text) else { return beep() }
            let edge: Fades.Edge = draft.field == .fadeIn ? .start : .end
            guard let fades = ClipInspection.fades(edge, ms: ms, for: draft.clips, in: session) else { return }
            edit { s throws(SessionError) in try s.setFades(fades) }
        }
    }

    /// Gives the keys to the lanes, so Space plays and Command-Z undoes the session.
    func focusLanes() {
        if let view = timelineView { view.window?.makeFirstResponder(view.lanes) }
    }

    func countInspector() { inspectorRuns += 1 }

    /// Widens the window to the minimum with the pane, inside the visible screen.
    private func widenForInspector() {
        guard let window else { return }
        let missing = SessionView.minWidth + InspectorView.width - window.contentRect(forFrameRect: window.frame).width
        guard missing > 0 else { return }
        var frame = window.frame
        frame.size.width += missing
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.size.width = min(frame.width, screen.width)
            frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
        }
        window.setFrame(frame, display: true, animate: false)
    }
}

extension AppDelegate {
    /// The title and the state of View > Show/Hide Inspector for the key window.
    var inspectorItem: (title: L10n, enabled: Bool) { inspectorItem(for: key) }

    func inspectorItem(for model: SessionWindow?) -> (title: L10n, enabled: Bool) {
        (model?.showsInspector == true ? .menuViewInspectorHide : .menuViewInspectorShow, model != nil)
    }
}
