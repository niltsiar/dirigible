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
            // The name is self-reported, so it is not in the title (decision 0050).
            Text(L10n.consentTitle.key).font(.headline)
            if let name = consent.agent.name {
                Text(verbatim: L10n.consentAgentLine.format(name)).fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: message).fixedSize(horizontal: false, vertical: true)
            if !consent.appTracks.isEmpty {
                Label {
                    Text(verbatim: L10n.consentAppTracks.format(list(consent.appTracks)))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if !consent.over.isEmpty {
                Label {
                    Text(verbatim: L10n.consentRecordOver.format(list(consent.over), startText))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if consent.offersGrant {
                VStack(alignment: .leading, spacing: 4) {
                    GrantBox(consent: consent).fixedSize()
                    Text(L10n.consentGrantHelp.key).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(L10n.consentDontRecord.key, role: .cancel) { Task { await model.answerConsent(record: false) } }
                    .keyboardShortcut(.cancelAction)
                // SwiftUI sets the enabled state of a hosted control from its environment.
                RecordButton(model: model).fixedSize().disabled(!consent.recordEnabled)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { model.consentSheetShown() }
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
/// do not stop `makeFirstResponder`. It is disabled until the click delay ends (decision 0050).
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

/// The grant checkbox (decision 0050): an AppKit switch that refuses the key focus, so Tab and
/// Space cannot change it with Keyboard navigation on. Only a click changes it.
private struct GrantBox: NSViewRepresentable {
    let consent: ConsentRequest

    func makeNSView(context: Context) -> GrantCheckbox {
        let box = GrantCheckbox(
            checkboxWithTitle: L10n.consentGrant.text, target: context.coordinator, action: #selector(Click.toggle(_:)))
        box.state = consent.grantChecked ? .on : .off
        return box
    }

    func updateNSView(_ box: GrantCheckbox, context: Context) { context.coordinator.consent = consent }

    func makeCoordinator() -> Click { Click(consent) }

    @MainActor final class Click: NSObject {
        weak var consent: ConsentRequest?
        init(_ consent: ConsentRequest) { self.consent = consent }
        @objc func toggle(_ box: NSButton) { consent?.grantChecked = box.state == .on }
    }
}

/// A button that never takes the key focus, so no key presses it.
class ClickOnlyButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
}

/// The grant checkbox of the sheet (decision 0050): only a click changes it, as Record.
final class GrantCheckbox: ClickOnlyButton {}
