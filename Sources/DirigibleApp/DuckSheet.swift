import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The values of the Duck Music Under Speech sheet (decision 0060): the speech tracks, the tracks
/// to duck, the depth in dB, and the attack and release in ms. The threshold and the hold keep the
/// defaults of `DuckShape`. The steppers keep each value in its range.
struct DuckDraft: Equatable {
    static let depths = -40...(-1)
    static let times = 0...5_000
    var speech: Set<TrackID>
    var music: Set<TrackID>
    var depth = -16
    var attack = 1_000
    var release = 1_000

    /// The lists from the roles only (plan gate 1 item 3): the dialogue tracks speak, and the music
    /// tracks duck. A track with no role is in no list.
    init(roles session: Session) {
        speech = Set(session.tracks.filter { $0.role == .dialogue }.map(\.id))
        music = Set(session.tracks.filter { $0.role == .music }.map(\.id))
    }

    /// The reason that Apply is off, as `Session.checkDuckLists` refuses the lists in `session`, or nil.
    func refusal(in session: Session) -> SessionError? {
        do throws(SessionError) {
            try session.checkDuckLists(speech: speech.sorted(), music: music.sorted())
            return nil
        } catch {
            return error
        }
    }

    func shape(sampleRate: Int) -> DuckShape {
        let base = DuckShape.defaults(sampleRate: sampleRate)
        return DuckShape(
            depth: Gain(dB: Double(depth))!, attack: Frames(attack * sampleRate / 1_000),
            release: Frames(release * sampleRate / 1_000), threshold: base.threshold, hold: base.hold)
    }
}

/// Tools > Duck Music Under Speech... (decision 0060): two checklists of the tracks, the depth,
/// attack, and release, and the note on what the duck replaces. Apply is off with the reason while
/// the lists are not valid. Cancel takes Esc, and Apply takes Return.
struct DuckSheet: View {
    let model: SessionWindow
    let tracks: [Track]
    @State private var draft: DuckDraft

    init(model: SessionWindow, tracks: [Track], draft: DuckDraft) {
        (self.model, self.tracks) = (model, tracks)
        _draft = State(initialValue: draft)
    }

    /// Nil with no studio: Apply then does nothing.
    private var refusal: SessionError? { model.studio.flatMap { draft.refusal(in: $0.session) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.sheetDuckTitle.key).font(.headline)
            HStack(alignment: .top, spacing: 24) {
                checklist(L10n.sheetDuckSpeech, \.speech)
                checklist(L10n.sheetDuckMusic, \.music)
            }
            Grid(alignment: .leading) {
                stepper(L10n.sheetDuckDepth, $draft.depth, DuckDraft.depths, step: 1, unit: .inspectorDecibels)
                stepper(L10n.sheetDuckAttack, $draft.attack, DuckDraft.times, step: 100, unit: .inspectorMilliseconds)
                stepper(L10n.sheetDuckRelease, $draft.release, DuckDraft.times, step: 100, unit: .inspectorMilliseconds)
            }
            Text(L10n.sheetDuckNote.key).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let refusal {
                Label {
                    Text(verbatim: L10n.message(for: .session(refusal), session: model.studio?.session))
                } icon: {
                    Image(systemName: WindowBanner.Kind.warning.symbol).foregroundStyle(.orange)
                }
            }
            HStack {
                Spacer()
                Button(L10n.alertCancel.key) { model.duckDraft = nil }.keyboardShortcut(.cancelAction)
                Button(L10n.sheetDuckApply.key) { Task { await model.duck(draft) } }
                    .keyboardShortcut(.defaultAction).disabled(refusal != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func checklist(_ title: L10n, _ list: WritableKeyPath<DuckDraft, Set<TrackID>>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.key).font(.subheadline.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tracks, id: \.id) { track in
                        Toggle(
                            isOn: Binding(
                                get: { draft[keyPath: list].contains(track.id) },
                                set: { on in
                                    if on {
                                        draft[keyPath: list].insert(track.id)
                                    } else {
                                        draft[keyPath: list].remove(track.id)
                                    }
                                })
                        ) { Text(verbatim: track.name) }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Both lists name the same tracks, so VoiceOver reads the list title on entry.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title.key))
    }

    private func stepper(
        _ title: L10n, _ value: Binding<Int>, _ range: ClosedRange<Int>, step: Int, unit: L10n
    ) -> some View {
        let shown = "\(value.wrappedValue) \(unit.text)"
        return GridRow {
            Text(title.key)
            Stepper(value: value, in: range, step: step) {
                Text(verbatim: shown).monospacedDigit()
            }
            .accessibilityLabel(Text(title.key))
            .accessibilityValue(Text(verbatim: shown))
        }
    }
}

extension SessionWindow {
    /// Tools > Duck Music Under Speech...: opens the sheet with the lists from the roles. A typed
    /// track name saves first. With a busy studio or a dialog, it does nothing.
    func startDuck() {
        commitDrafts()
        guard !dialogShowing, let studio = idleStudio else { return }
        duckDraft = DuckDraft(roles: studio.session)
    }

    /// Apply of the sheet: ducks the music of `draft` under its speech in the selection range, or in
    /// the hull of the set clips, else in the whole session, in one undo entry (decision 0060).
    /// Zero speech runs show the reason in a banner, and so does a speech file that did not read,
    /// with its path. The banner Cancel shows nothing; another error shows the alert.
    func duck(_ draft: DuckDraft) async {
        duckDraft = nil
        duckReport = nil
        guard let studio = idleStudio else { return }
        let paths = { (files: [FileID]) in files.map { studio.session.files[$0]?.path ?? $0.rawValue } }
        let tracks = studio.session.tracks.map(\.id)
        let range = timeline.selection.span(in: studio.session)
        duckProgress = 0
        duckPresses += 1
        defer { duckProgress = nil }
        do throws(StudioError) {
            let result = try await studio.duck(
                speech: tracks.filter(draft.speech.contains), music: tracks.filter(draft.music.contains), range: range,
                shape: draft.shape(sampleRate: studio.session.sampleRate)
            ) { [weak self] fraction in self?.duckProgress = fraction }
            if !result.unread.isEmpty {
                let banner = WindowBanner.duckUnread(paths(result.unread), press: duckPresses)
                duckReport = DuckReportShown(banner: banner, revision: studio.sessionRevision)
            }
        } catch .duckCancelled {
            // The banner Cancel: the user asked for it, so no alert.
        } catch .session(.noSpeech(_, let threshold, let unread)) {
            duckReport = DuckReportShown(
                banner: .duckNoSpeech(threshold: threshold, unread: paths(unread), press: duckPresses),
                revision: studio.sessionRevision)
        } catch {
            alert = .error(error)
        }
    }
}
