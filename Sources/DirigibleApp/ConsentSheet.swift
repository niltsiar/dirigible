import AppKit
import DirigibleCore
import DirigibleMCP
import SwiftUI

/// The consent sheet of an agent record request (decision 0048, `ui-panel.md` of the run). No
/// button takes Return: consent is a click, because the sheet can open while the user types.
/// Escape is Don't Record.
struct ConsentSheet: View {
    let model: SessionWindow
    let consent: ConsentRequest
    let sampleRate: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title).font(.headline)
            Text(verbatim: message).fixedSize(horizontal: false, vertical: true)
            if !consent.over.isEmpty {
                Label {
                    Text(verbatim: L10n.consentRecordOver.format(list(consent.over), startText))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            HStack {
                Spacer()
                Button(L10n.consentDontRecord.key, role: .cancel) { Task { await model.answerConsent(record: false) } }
                    .keyboardShortcut(.cancelAction)
                RecordButton(model: model).fixedSize()
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var title: String {
        consent.agent.name.map { L10n.consentTitle.format($0) } ?? L10n.consentTitleUnnamed.text
    }

    private var message: String {
        let fraction: Duration.UnitsFormatStyle.FractionalPartDisplayStrategy =
            consent.seconds.rounded() == consent.seconds ? .hide : .show(length: 1)
        let length = Duration.seconds(consent.seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .wide, fractionalPart: fraction))
        let limit = Int(RecordRequest.answerLimit.components.seconds)
        return L10n.consentMessage.format(length, list(consent.names), startText, limit)
    }

    private var startText: String { timeDisplayText(consent.start, rate: sampleRate, playing: false) }

    private func list(_ names: [String]) -> String { ListFormatter.localizedString(byJoining: names) }
}

/// Record of the consent sheet: an AppKit button that refuses the key focus, so Tab and Space
/// cannot press it with Keyboard navigation on. `.focusable(false)` and `refusesFirstResponder`
/// do not stop `makeFirstResponder`.
private struct RecordButton: NSViewRepresentable {
    let model: SessionWindow

    func makeNSView(context: Context) -> ClickOnlyButton {
        let button = ClickOnlyButton(
            title: L10n.transportRecord.text, target: context.coordinator, action: #selector(Click.record))
        return button
    }

    func updateNSView(_ button: ClickOnlyButton, context: Context) { context.coordinator.model = model }

    func makeCoordinator() -> Click { Click(model) }

    @MainActor final class Click: NSObject {
        weak var model: SessionWindow?
        init(_ model: SessionWindow) { self.model = model }
        @objc func record() { Task { await model?.answerConsent(record: true) } }
    }
}

/// A button that never takes the key focus, so no key presses it.
final class ClickOnlyButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
}
