import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The values of the Repair Sound sheet (decision 0064): the three repairs in chain order, each
/// with a check box that starts off, and the clips of the selection. The sliders start at the values
/// of the last Repair press, else at the standard values. The corner sliders stop at the highest whole Hz that
/// the session rate takes (C19), so a value of the sheet is never refused by the render.
struct RepairDraft: Equatable {
    static let rumbleHertzKey = "repair.rumbleHz"
    static let deessDecibelsKey = "repair.deessDb"
    static let deessHertzKey = "repair.deessHz"

    /// The rows of the sheet, in chain order.
    enum Row: CaseIterable {
        case declip, rumble, deess

        var kind: Effect.Kind {
            switch self {
            case .declip: .declip
            case .rumble: .rumble
            case .deess: .deess
            }
        }
    }

    /// The clips of the selection by the rule of Auto Level (decision 0031), whatever their role.
    let clips: [ClipID]
    let sampleRate: Int
    var declip = false
    var rumble = false
    var rumbleHertz: Int
    var deess = false
    var deessDecibels: Int
    var deessHertz: Int
    /// True when the More group of the de-ess row shows; it starts collapsed.
    var showsMore = false
    /// The line of the last preview fault, until the next preview starts.
    var previewFault: String?

    init(clips: [ClipID], sampleRate: Int, defaults: UserDefaults?) {
        (self.clips, self.sampleRate) = (clips, sampleRate)
        rumbleHertz =
            (defaults?.object(forKey: Self.rumbleHertzKey) as? Int).flatMap(Rumble.init(hertz:))?.hertz
            ?? Rumble.standard.hertz
        deessDecibels =
            (defaults?.object(forKey: Self.deessDecibelsKey) as? Int)
            .flatMap { DeEss(hertz: DeEss.standard.hertz, decibels: $0) }?.decibels ?? DeEss.standard.decibels
        deessHertz = defaults?.object(forKey: Self.deessHertzKey) as? Int ?? DeEss.standard.hertz
        if let top = rumbleMax { rumbleHertz = min(max(rumbleHertz, Rumble.range.lowerBound), top) }
        if let top = frequencyMax {
            deessHertz = min(max(deessHertz, DeEss.hertzRange.lowerBound), top)
        } else {
            deess = false
        }
    }

    /// The highest value of `range` that the session rate takes, or nil when no value fits.
    private func top(of range: ClosedRange<Int>) -> Int? {
        let limit = cornerLimit(rate: sampleRate)
        return limit >= range.lowerBound ? min(range.upperBound, limit) : nil
    }

    /// The top of the rumble slider, or nil when the rate takes no rumble cutoff.
    var rumbleMax: Int? { top(of: Rumble.range) }

    /// The top of the de-ess frequency slider, or nil when the rate takes no de-ess.
    var frequencyMax: Int? { top(of: DeEss.hertzRange) }

    /// The lowest session rate that takes the lowest de-ess frequency, for the line of a row that is off.
    static var lowestDeessRate: Int { lowestRate(takingCorner: DeEss.hertzRange.lowerBound) }

    /// The effects of the checked boxes, or nil when no box is on.
    var treatment: Treatment? {
        var effects: [Effect] = []
        if declip { effects.append(.declip(.standard)) }
        if rumble, let hertz = Rumble(hertz: rumbleHertz) { effects.append(.rumble(hertz)) }
        if deess, let shape = DeEss(hertz: deessHertz, decibels: deessDecibels) { effects.append(.deess(shape)) }
        return Treatment(effects)
    }

    /// The request of Repair and Preview. A cleared box takes nothing out of a clip: the sheet
    /// starts with all boxes off, so it adds repairs, and Restore Original Audio takes them back.
    var request: ClipRenderRequest? { treatment.map { ClipRenderRequest($0) } }

    /// The sheet title with the count of clips. `text` gives the value of a key, so a test can read a table.
    func title(text: (L10n) -> String = { $0.text }) -> String {
        clips.count == 1
            ? text(.sheetRepairTitleOne) : String(format: text(.sheetRepairTitleMany), locale: .current, clips.count)
    }

    /// Repair is on when a box is on.
    var canRepair: Bool { treatment != nil && !clips.isEmpty }

    /// The line that says why Repair is off, or nil when it is on.
    var reason: L10n? { treatment == nil ? .sheetRepairNone : nil }

    /// The clip that Preview plays: the first clip, or nil when no box is on.
    var previewClip: ClipID? { treatment == nil ? nil : clips.first }

    func remember(in defaults: UserDefaults?) {
        defaults?.set(rumbleHertz, forKey: Self.rumbleHertzKey)
        defaults?.set(deessDecibels, forKey: Self.deessDecibelsKey)
        defaults?.set(deessHertz, forKey: Self.deessHertzKey)
    }
}

/// Tools > Repair Sound... (decision 0064): one check box with one caption for each repair, in
/// chain order, the sliders of the checked repairs, Preview with Result and Removed Sound, and the
/// buttons. Return is Repair, Escape is Cancel, and Space starts or stops Preview unless a check
/// box has the focus.
struct RepairSheet: View {
    let model: SessionWindow
    let studio: Studio
    @State private var draft: RepairDraft
    @State private var listen = Listen.result

    init(model: SessionWindow, studio: Studio, draft: RepairDraft) {
        (self.model, self.studio) = (model, studio)
        _draft = State(initialValue: draft)
    }

    private var previewing: Bool { studio.effectPreviewState != .stopped }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: draft.title()).font(.headline)
            // One grid, so the slider labels of all rows share one column. A view outside a grid
            // row spans both columns.
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(RepairDraft.Row.allCases, id: \.self) { row in
                    self.row(row)
                }
            }
            if let reason = draft.reason { note(reason.text) }
            Divider()
            preview
            if let fault = model.repairDraft?.previewFault { note(fault) }
            HStack {
                Spacer()
                Button(L10n.alertCancel.key) { model.cancelRepair() }.keyboardShortcut(.cancelAction)
                Button(L10n.sheetRepairApply.key) { model.applyRepair(draft) }
                    .keyboardShortcut(.defaultAction).disabled(!draft.canRepair)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onKeyPress(.space) {
            togglePreview()
            return .handled
        }
        .onChange(of: draft.request) { restartPreview() }
        .onChange(of: listen) { restartPreview() }
        .onChange(of: studio.effectPreviewState) { old, new in
            if old == .updating, new == .playing { model.chrome?.announce(L10n.sheetDenoisePlaying.text, .medium) }
        }
        .onDisappear { studio.stopEffectPreview() }
    }

    @ViewBuilder private func row(_ row: RepairDraft.Row) -> some View {
        switch row {
        case .declip:
            Toggle(L10n.sheetRepairDeclip.key, isOn: $draft.declip).toggleStyle(.checkbox)
            note(L10n.sheetRepairDeclipNote.text).padding(.leading, 20)
        case .rumble:
            Toggle(L10n.sheetRepairRumble.key, isOn: $draft.rumble).toggleStyle(.checkbox)
                .disabled(draft.rumbleMax == nil)
            note(L10n.sheetRepairRumbleNote.format(draft.rumbleHertz)).padding(.leading, 20)
            if let top = draft.rumbleMax {
                slider(
                    .sheetRepairCutoff, .sheetRepairRumble, $draft.rumbleHertz, Rumble.range.lowerBound...top,
                    unit: .inspectorHertz, enabled: draft.rumble)
            }
        case .deess:
            Toggle(L10n.sheetRepairDeess.key, isOn: $draft.deess).toggleStyle(.checkbox)
                .disabled(draft.frequencyMax == nil)
            if let top = draft.frequencyMax {
                note(L10n.sheetRepairDeessNote.format(draft.deessDecibels)).padding(.leading, 20)
                slider(
                    .sheetRepairAmount, .sheetRepairAmount, $draft.deessDecibels, DeEss.decibelRange,
                    unit: .inspectorDecibels, enabled: draft.deess)
                // The slider sits in the grid under the group, so its label stays in the label column.
                DisclosureGroup(L10n.sheetRepairMore.key, isExpanded: $draft.showsMore) {}
                    .padding(.leading, 20)
                if draft.showsMore {
                    slider(
                        .sheetRepairFrequency, .sheetRepairFrequency, $draft.deessHertz,
                        DeEss.hertzRange.lowerBound...top, unit: .inspectorHertz, enabled: draft.deess)
                }
            } else {
                note(L10n.errorDenoiseCornerRate.format(DeEss.hertzRange.lowerBound, RepairDraft.lowestDeessRate))
                    .padding(.leading, 20)
            }
        }
    }

    /// A grid row: the visible `label` in the label column, then the slider and its value. The slider
    /// keeps the accessibility label `title`. A modifier on the row would make it one cell that spans
    /// the grid, so `enabled` goes in.
    private func slider(
        _ label: L10n, _ title: L10n, _ value: Binding<Int>, _ range: ClosedRange<Int>, unit: L10n, enabled: Bool
    ) -> some View {
        let shown = "\(value.wrappedValue) \(unit.text)"
        return GridRow(alignment: .center) {
            Text(label.key).padding(.leading, 20).gridColumnAlignment(.leading)
            HStack {
                Slider(
                    value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }),
                    in: Double(range.lowerBound)...Double(range.upperBound)
                )
                .accessibilityLabel(Text(title.key))
                .accessibilityValue(Text(verbatim: shown))
                Text(verbatim: shown).monospacedDigit().frame(width: 72, alignment: .trailing)
            }
            .disabled(!enabled)
        }
    }

    private var preview: some View {
        HStack {
            Button {
                togglePreview()
            } label: {
                Text(previewTitle.key)
            }
            .disabled(draft.previewClip == nil)
            Picker(L10n.sheetDenoiseListen.key, selection: $listen) {
                Text(L10n.sheetDenoiseResult.key).tag(Listen.result)
                Text(L10n.sheetDenoiseRemoved.key).tag(Listen.removedSound)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .disabled(draft.previewClip == nil)
        }
    }

    private var previewTitle: L10n {
        switch studio.effectPreviewState {
        case .stopped: .sheetDenoisePreview
        case .updating: .sheetDenoiseUpdating
        case .playing: .sheetDenoiseStop
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func togglePreview() {
        if previewing { studio.stopEffectPreview() } else { restartPreview(force: true) }
    }

    /// A change of a box, a slider, or the listen mode swaps the window of a running preview.
    private func restartPreview(force: Bool = false) {
        guard force || previewing else { return }
        let (draft, listen) = (draft, listen)
        Task { await model.previewRepair(draft, listen: listen) }
    }
}
