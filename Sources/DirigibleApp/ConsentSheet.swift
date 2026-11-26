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
            if let preRoll = consent.preRoll {
                Text(verbatim: consentPreRollText(start: startText, seconds: preRoll))
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                    GrantBox(consent: consent) { model.grantBoxTurnedOn() }.fixedSize()
                    let hours = (
                        grantHours(RecordRequest.grantLifetime), grantHours(.seconds(RecordRequest.grantTakeSeconds))
                    )
                    Text(verbatim: L10n.consentGrantHelp.format(hours.0, hours.1)).font(.caption)
                        .foregroundStyle(.secondary)
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
        consentMessageText(
            seconds: consent.seconds, names: list(consent.names), start: startText, limit: RecordRequest.answerLimit)
    }

    private var startText: String { timeDisplayText(consent.start, rate: sampleRate, playing: false) }

    private func list(_ names: [String]) -> String { ListFormatter.localizedString(byJoining: names) }
}

/// The body of the consent sheet. The length of the take and the time to answer have one unit form, in
/// words, in the number format of `locale`.
func consentMessageText(
    seconds: Double, names: String, start: String, limit: Duration, locale: Locale = .current,
    format: String = L10n.consentMessage.text
) -> String {
    func wide(_ seconds: Double) -> String {
        let fraction: Duration.UnitsFormatStyle.FractionalPartDisplayStrategy =
            seconds.rounded() == seconds ? .hide : .show(length: 1)
        return Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .wide, fractionalPart: fraction).locale(locale))
    }
    return String(
        format: format, locale: locale, wide(seconds), names, start, wide(Double(limit.components.seconds)))
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
    let turnedOn: @MainActor () -> Void

    func makeNSView(context: Context) -> GrantCheckbox {
        let box = GrantCheckbox(
            checkboxWithTitle: L10n.consentGrant.text, target: context.coordinator, action: #selector(Click.toggle(_:)))
        box.state = consent.grantChecked ? .on : .off
        return box
    }

    func updateNSView(_ box: GrantCheckbox, context: Context) {
        (context.coordinator.consent, context.coordinator.turnedOn) = (consent, turnedOn)
    }

    func makeCoordinator() -> Click { Click(consent, turnedOn) }

    @MainActor final class Click: NSObject {
        weak var consent: ConsentRequest?
        var turnedOn: @MainActor () -> Void
        init(_ consent: ConsentRequest, _ turnedOn: @escaping @MainActor () -> Void) {
            (self.consent, self.turnedOn) = (consent, turnedOn)
        }
        @objc func toggle(_ box: NSButton) {
            consent?.grantChecked = box.state == .on
            if box.state == .on { turnedOn() }
        }
    }
}

/// A button that never takes the key focus, so no key presses it.
class ClickOnlyButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
}

/// The grant checkbox of the sheet (decision 0050): only a click changes it, as Record.
final class GrantCheckbox: ClickOnlyButton {}

/// The hours of `duration` in the words of `locale`: "1 hour", "2 horas". The help line of the
/// grant gets its hours from the constants of decision 0050.
func grantHours(_ duration: Duration, _ locale: Locale = .autoupdatingCurrent) -> String {
    duration.formatted(.units(allowed: [.hours], width: .wide).locale(locale))
}

/// The pre-roll line of the sheet, "Starts recording at 1:02:03, after a 3 s pre-roll.": `start`
/// is the start time text. `text` gives the value of a key.
func consentPreRollText(
    start: String, seconds: Int, locale: Locale = .current, text: (L10n) -> String = { $0.text }
) -> String {
    String(
        format: text(.consentPreRollLine), locale: locale, start, preRollLengthText(seconds: seconds, locale: locale))
}
