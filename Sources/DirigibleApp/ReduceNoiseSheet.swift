import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The values of the Reduce Noise sheet (decision 0054): the noise reduction with its dial, the
/// hum removal with its frequency, and the clips of the selection. Each check box starts on at the
/// stored value when each clip that it reads holds its kind at that one value. Else it starts at
/// the last Reduce Noise button press, else at the first use values: 12 dB, noise on, hum off.
struct DenoiseDraft: Equatable {
    static let noiseKey = "denoise.noise"
    static let decibelsKey = "denoise.decibels"
    static let humKey = "denoise.hum"
    static let humHzKey = "denoise.humHz"

    /// The regions of the Mac with a 60 Hz mains frequency, for the first use hum frequency. Japan
    /// has two grids and gets 50 Hz. Source: Wikipedia, "Mains electricity by country" (60 Hz
    /// only), read 2026-10-28.
    static let hz60Regions: Set<String> = [
        "AS", "AI", "AG", "AW", "BS", "BZ", "BM", "BR", "VG", "CA", "KY", "CO", "CR", "CU", "DO", "EC", "SV", "FM",
        "GU",
        "GT", "GY", "HT", "HN", "LR", "MX", "MS", "NI", "PW", "PA", "PE", "PH", "PR", "KN", "MF", "SA", "SX", "KR",
        "SR", "TW", "TT", "US", "VI", "VE", "VC",
    ]

    var noise: Bool
    var decibels: Int
    var hum: Bool
    var frequency: Hum
    /// The clips of the selection by the rule of Auto Level (decision 0031), whatever their role.
    let clips: Set<ClipID>
    /// The mixed line of the noise, read on the clips that the noise accepts.
    let mixedNoise: Mixed?
    /// The mixed line of the hum, read on each clip.
    let mixedHum: Mixed?
    /// The line of the last preview fault, until the next preview starts.
    var previewFault: String?

    /// The clips that hold a kind, of the clips that a check box reads, when they do not all hold
    /// it at one value.
    struct Mixed: Equatable {
        let holding: Int
        let of: Int
    }

    init(clips: Set<ClipID>, in session: Session, defaults: UserDefaults?, region: Locale.Region?) {
        self.clips = clips
        noise = defaults?.object(forKey: Self.noiseKey) as? Bool ?? true
        let amount = defaults?.object(forKey: Self.decibelsKey) as? Int
        var decibels = amount.flatMap(NoiseReduction.init(decibels:))?.decibels ?? NoiseReduction.standard.decibels
        hum = defaults?.object(forKey: Self.humKey) as? Bool ?? false
        var frequency =
            (defaults?.object(forKey: Self.humHzKey) as? Int).flatMap(Hum.init(rawValue:))
            ?? (region.map { Self.hz60Regions.contains($0.identifier) } == true ? .hz60 : .hz50)

        let accepted = Treatment(.noise(.standard))
        var amounts: [Int?] = []
        var hums: [Hum?] = []
        for id in clips {
            guard let found = session.clip(id) else { continue }
            let effects = session.origins(of: id).flatMap(\.treatment.effects)
            if accepted.accepts(session.track(found.track)?.role) {
                amounts.append(effects.lazy.compactMap { if case .noise(let n) = $0 { n.decibels } else { nil } }.first)
            }
            hums.append(effects.lazy.compactMap { if case .hum(let h) = $0 { h } else { nil } }.first)
        }
        let noiseStart = Self.start(amounts)
        if let only = noiseStart.value { (noise, decibels) = (true, only) }
        let humStart = Self.start(hums)
        if let only = humStart.value { (hum, frequency) = (true, only) }
        (mixedNoise, mixedHum) = (noiseStart.mixed, humStart.mixed)
        (self.decibels, self.frequency) = (decibels, frequency)
    }

    /// The start of a check box from the stored value of each clip that it reads: the one value
    /// when each clip holds it, no value when no clip holds the kind, else no value and the mixed
    /// line.
    private static func start<Value: Hashable>(_ stored: [Value?]) -> (value: Value?, mixed: Mixed?) {
        let held = stored.compactMap { $0 }
        if held.isEmpty { return (nil, nil) }
        if held.count == stored.count, Set(held).count == 1 { return (held[0], nil) }
        return (nil, Mixed(holding: held.count, of: stored.count))
    }

    /// The treatment of the check boxes, or nil when both are off or the dial is out of range.
    var treatment: Treatment? {
        var effects: [Effect] = []
        if hum { effects.append(.hum(frequency)) }
        if noise {
            guard let reduction = NoiseReduction(decibels: decibels) else { return nil }
            effects.append(.noise(reduction))
        }
        return Treatment(effects)
    }

    /// The request of Reduce Noise and Preview: the effects of the check boxes, and the kind of
    /// each cleared box removed from the stored levels, so each clip gets exactly the checked
    /// effects.
    var request: ClipRenderRequest? { treatment.map { ClipRenderRequest($0, removing: [.hum, .noise]) } }

    /// The clips that the treatment takes, in track order and then in clip order.
    func accepted(in session: Session) -> [ClipID] {
        guard let treatment else { return [] }
        return session.tracks.filter { treatment.accepts($0.role) }.flatMap { $0.clips.map(\.id) }
            .filter(clips.contains)
    }

    /// The clips that the treatment leaves out: the music and effects clips while noise is on.
    func skippedCount(in session: Session) -> Int {
        treatment == nil ? 0 : clips.count - accepted(in: session).count
    }

    func canApply(in session: Session) -> Bool { !accepted(in: session).isEmpty }

    /// The clip that Preview plays: the first accepted clip, or nil, and then Preview is off.
    func previewClip(in session: Session) -> ClipID? { accepted(in: session).first }

    func remember(in defaults: UserDefaults?) {
        defaults?.set(noise, forKey: Self.noiseKey)
        defaults?.set(decibels, forKey: Self.decibelsKey)
        defaults?.set(hum, forKey: Self.humKey)
        defaults?.set(frequency.rawValue, forKey: Self.humHzKey)
    }
}

/// Tools > Reduce Noise... (decision 0054): the two check boxes with the dial and the frequency,
/// the lines on the clips that the treatment skips and on stored values that differ, Preview with
/// Result and Removed Sound, and the buttons. Return is Reduce Noise, Escape is Cancel, and Space
/// starts or stops Preview unless a check box or the pop-up has the focus.
struct ReduceNoiseSheet: View {
    let model: SessionWindow
    let studio: Studio
    @State private var draft: DenoiseDraft
    @State private var listen = Listen.result

    init(model: SessionWindow, studio: Studio, draft: DenoiseDraft) {
        (self.model, self.studio) = (model, studio)
        _draft = State(initialValue: draft)
    }

    private var session: Session { studio.session }
    private var previewing: Bool { studio.effectPreviewState != .stopped }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.sheetDenoiseTitle.key).font(.headline)
            Toggle(L10n.sheetDenoiseNoise.key, isOn: $draft.noise).toggleStyle(.checkbox)
            dial.disabled(!draft.noise).padding(.leading, 20)
            if let mixed = draft.mixedNoise {
                note(L10n.sheetDenoiseMixedNoise.format(mixed.holding, mixed.of)).padding(.leading, 20)
            }
            HStack {
                Toggle(L10n.sheetDenoiseHum.key, isOn: $draft.hum).toggleStyle(.checkbox)
                Picker(L10n.sheetDenoiseHumFrequency.key, selection: $draft.frequency) {
                    ForEach(Hum.allCases, id: \.self) {
                        Text(verbatim: "\($0.rawValue) \(L10n.inspectorHertz.text)").tag($0)
                    }
                }
                .labelsHidden().fixedSize().disabled(!draft.hum)
            }
            if let mixed = draft.mixedHum {
                note(L10n.sheetDenoiseMixedHum.format(mixed.holding, mixed.of)).padding(.leading, 20)
            }
            if let line = skippedLine { note(line) }
            Divider()
            preview
            if let fault = model.denoiseDraft?.previewFault { note(fault) }
            HStack {
                Spacer()
                Button(L10n.alertCancel.key) { model.cancelDenoise() }.keyboardShortcut(.cancelAction)
                Button(L10n.sheetDenoiseApply.key) { model.applyDenoise(draft) }
                    .keyboardShortcut(.defaultAction).disabled(!draft.canApply(in: session))
            }
        }
        .padding(20)
        .frame(width: 480)
        .onKeyPress(.space) {
            togglePreview()
            return .handled
        }
        .onChange(of: draft) { restartPreview() }
        .onChange(of: listen) { restartPreview() }
        .onChange(of: studio.effectPreviewState) { old, new in
            if old == .updating, new == .playing { model.chrome?.announce(L10n.sheetDenoisePlaying.text, .medium) }
        }
        .onDisappear { studio.stopEffectPreview() }
    }

    private var dial: some View {
        let help = draft.mixedNoise.map { L10n.sheetDenoiseMixedNoise.format($0.holding, $0.of) }
        return HStack {
            Slider(
                value: Binding(get: { Double(draft.decibels) }, set: { draft.decibels = Int($0) }),
                in: Double(NoiseReduction.range.lowerBound)...Double(NoiseReduction.range.upperBound), step: 1
            )
            .accessibilityLabel(Text(L10n.sheetDenoiseNoise.key))
            .accessibilityValue(Text(verbatim: L10n.sheetDenoiseValue.format(draft.decibels)))
            .accessibilityHint(Text(verbatim: help ?? ""))
            Text(verbatim: "\(draft.decibels) \(L10n.inspectorDecibels.text)").monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
    }

    private var preview: some View {
        HStack {
            Button {
                togglePreview()
            } label: {
                Text(previewTitle.key)
            }
            .disabled(draft.previewClip(in: session) == nil)
            Picker(L10n.sheetDenoiseListen.key, selection: $listen) {
                Text(L10n.sheetDenoiseResult.key).tag(Listen.result)
                Text(L10n.sheetDenoiseRemoved.key).tag(Listen.removedSound)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .disabled(draft.previewClip(in: session) == nil)
        }
    }

    private var previewTitle: L10n {
        switch studio.effectPreviewState {
        case .stopped: .sheetDenoisePreview
        case .updating: .sheetDenoiseUpdating
        case .playing: .sheetDenoiseStop
        }
    }

    /// The count of the clips that the treatment leaves out, and what they miss.
    private var skippedLine: String? {
        let count = draft.skippedCount(in: session)
        guard count > 0 else { return nil }
        let key: L10n =
            switch (draft.hum, count == 1) {
            case (false, true): .sheetDenoiseSkippedOne
            case (false, false): .sheetDenoiseSkippedMany
            case (true, true): .sheetDenoiseSkippedHumOne
            case (true, false): .sheetDenoiseSkippedHumMany
            }
        return key.format(count)
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func togglePreview() {
        if previewing { studio.stopEffectPreview() } else { restartPreview(force: true) }
    }

    /// A change of the dial, a check box, the frequency, or the listen mode swaps the window of
    /// a running preview. The old loop plays until the new window is ready.
    private func restartPreview(force: Bool = false) {
        guard force || previewing else { return }
        let (draft, listen) = (draft, listen)
        Task { await model.previewDenoise(draft, listen: listen) }
    }
}
