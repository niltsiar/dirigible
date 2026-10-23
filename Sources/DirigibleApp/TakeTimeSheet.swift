import DirigibleAudio
import DirigibleCore
import SwiftUI

/// The values of the Go to Take Time sheet (decision 0061): the takes with audio, the take of the
/// popup, the typed time, and the reason that the last OK did not move the playhead.
struct TakeTimeDraft: Equatable {
    enum Refusal: Equatable {
        /// The text is not `H:MM:SS.mmm`, `M:SS`, or seconds.
        case format
        /// No clip plays that take time: an edit removed it, or the take has no audio there.
        case removed
    }

    /// The takes with audio, in take order.
    let takes: [Int]
    var take: Int
    var text = ""
    var refusal: Refusal?
}

/// The take frame of a time typed in the sheet: `H:MM:SS.mmm`, `M:SS`, or seconds, each with an
/// optional fraction of 1 to 3 digits, from the record start of the take. It rounds to the frame,
/// half away from zero. Nil for another text, or a time that no take can hold.
func takeFrame(_ text: String, rate: Int) -> Int? {
    let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
    let fields = parts[0].split(separator: ":", omittingEmptySubsequences: false)
    let fraction = parts.count == 2 ? parts[1] : "0"
    // Nine digits at most in each field, so the sums below cannot overflow.
    func digits(_ part: Substring, _ count: ClosedRange<Int>) -> Int? {
        count.contains(part.count) && part.allSatisfy { $0.isASCII && $0.isNumber } ? Int(part) : nil
    }
    let rest = fields.dropFirst().compactMap { digits($0, 1...2) }.filter { $0 < 60 }
    guard parts.count <= 2, fields.count <= 3, rest.count == fields.count - 1, let lead = digits(fields[0], 1...9),
        let fractionDigits = digits(fraction, 1...3)
    else { return nil }
    let seconds = rest.reduce(lead) { $0 * 60 + $1 }
    let milliseconds = seconds * 1000 + fractionDigits * [100, 10, 1][fraction.count - 1]
    let (product, overflow) = milliseconds.multipliedReportingOverflow(by: rate)
    guard !overflow else { return nil }
    let frame = product / 1000 + (product % 1000 >= 500 ? 1 : 0)
    return TakeMap.takeFrames.contains(frame) ? frame : nil
}

/// Transport > Go to Take Time... (decision 0061): one time field, and a take popup when the
/// session has two or more takes with audio. OK moves the playhead to the first place of that time
/// on the timeline; the sheet stays and says why when it cannot. Cancel takes Esc, and OK Return.
struct TakeTimeSheet: View {
    let model: SessionWindow
    let draft: TakeTimeDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.sheetTakeTimeTitle.key).font(.headline)
            Grid(alignment: .leading) {
                if draft.takes.count > 1 {
                    GridRow {
                        Text(L10n.sheetTakeTimeTake.key)
                        Picker(L10n.sheetTakeTimeTake.key, selection: binding(\.take)) {
                            ForEach(draft.takes, id: \.self) { take in
                                Text(verbatim: L10n.sheetTakeTimeItem.format(take)).tag(take)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                GridRow {
                    Text(L10n.sheetTakeTimeField.key)
                    TextField(L10n.sheetTakeTimeField.key, text: binding(\.text), prompt: Text(verbatim: "0:00:00.000"))
                        .labelsHidden()
                        .accessibilityLabel(Text(L10n.sheetTakeTimeField.key))
                        .monospacedDigit()
                        .frame(width: 140)
                }
            }
            if let refusal = draft.refusal {
                Label {
                    Text(verbatim: refusalText(refusal))
                } icon: {
                    Image(systemName: WindowBanner.Kind.warning.symbol).foregroundStyle(.orange)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L10n.alertCancel.key) { model.takeTimeDraft = nil }.keyboardShortcut(.cancelAction)
                Button(L10n.alertOK.key) { Task { await model.goToTakeTime() } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func refusalText(_ refusal: TakeTimeDraft.Refusal) -> String {
        switch refusal {
        case .format: L10n.sheetTakeTimeFormat.text
        case .removed: L10n.sheetTakeTimeRemoved.format(draft.take)
        }
    }

    /// A field of the draft of the model. While the sheet closes, the model has no draft, so the
    /// field shows the last one.
    private func binding<Value>(_ field: WritableKeyPath<TakeTimeDraft, Value>) -> Binding<Value> {
        Binding(
            get: { (model.takeTimeDraft ?? draft)[keyPath: field] },
            set: { model.takeTimeDraft?[keyPath: field] = $0 })
    }
}

extension SessionWindow {
    /// Go to Take Time is off with no take audio and while the studio is busy, for example during
    /// a take.
    var canGoToTakeTime: Bool { idleStudio?.takeMap.map.sync.isEmpty == false }

    /// Transport > Go to Take Time...: opens the sheet. The popup starts at the take under the
    /// playhead, else at the first take. A typed track name saves first.
    func startTakeTime() {
        commitDrafts()
        guard takeTimeDraft == nil, let studio = idleStudio else { return }
        let map = studio.takeMap.map
        let takes = map.sync.keys.sorted()
        guard let first = takes.first else { return }
        let under = studio.session.tracks.lazy.compactMap { map.take(atTimeline: studio.playhead, on: $0.id) }.first
        takeTimeDraft = TakeTimeDraft(takes: takes, take: under?.take ?? first)
    }

    /// OK of the sheet: moves the playhead to the first timeline place of the typed take time.
    /// A text that does not parse, or a time that no clip plays, keeps the sheet and its text.
    func goToTakeTime() async {
        guard let draft = takeTimeDraft, let studio = idleStudio else { return }
        guard let frame = takeFrame(draft.text, rate: studio.session.sampleRate) else {
            takeTimeDraft?.refusal = .format
            return
        }
        guard let place = studio.takeMap.map.timeline(atTake: frame, take: draft.take).first else {
            takeTimeDraft?.refusal = .removed
            return
        }
        takeTimeDraft = nil
        await studio.perform(.seek(.frame(place.frame)))
    }
}
