import AppKit
import Foundation
import SwiftUI
import Testing

@testable import DirigibleApp

/// Criterion P10 (run 2026-10-28-pre-roll): the pre-roll length is an app preference of 1 to 10 whole
/// seconds, default 3, and Settings shows it as "3 s" next to the label "Pre-roll".
@MainActor struct PreRollPreferenceTests {
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "preroll-\(UUID().uuidString)"))
    }

    private func app() -> AppDelegate { AppDelegate(recordings: nil, defaults: defaults) }

    @Test func noStoredValueReadsThree() {
        #expect(app().preRollSeconds == 3)
    }

    @Test(arguments: [(0, 1), (-4, 1), (1, 1), (4, 4), (10, 10), (60, 10)])
    func aStoredValueClamps(stored: Int, read: Int) {
        defaults.set(stored, forKey: AppDelegate.preRollKey)
        #expect(app().preRollSeconds == read)
    }

    @Test func aStoredValueThatIsNotAWholeNumberReadsThree() {
        defaults.set("long", forKey: AppDelegate.preRollKey)
        #expect(app().preRollSeconds == 3)
        defaults.set(2.5, forKey: AppDelegate.preRollKey)
        #expect(app().preRollSeconds == 3)
    }

    /// A step up from 10 stays 10, and a step down from 1 stays 1: the stepper writes through this setter.
    @Test func stepperStaysInRange() {
        let app = app()
        app.preRollSeconds = 11
        #expect(app.preRollSeconds == 10 && defaults.integer(forKey: AppDelegate.preRollKey) == 10)
        app.preRollSeconds = 0
        #expect(app.preRollSeconds == 1 && defaults.integer(forKey: AppDelegate.preRollKey) == 1)
        app.preRollSeconds = 4
        #expect(self.app().preRollSeconds == 4, "the next launch reads the pick")
    }

    /// The Settings label holds no value: the length with its unit is in the control column.
    @Test func theSettingsLabelHoldsNoValue() throws {
        var withValue: [String] = []
        for language in AppLanguage.allCases.map(\.rawValue) {
            let label = try #require(stringsTable(language)[L10n.settingsPreRoll.rawValue], "\(language)")
            if label.contains("%") || label.contains(":") { withValue.append("\(language): \(label)") }
        }
        #expect(withValue == [])
    }

    /// The value "3 s" of the Pre-roll row starts in the control column of Settings, where the Language
    /// pop-up starts. A value left of that column reads as part of the label.
    @Test func theSettingsValueStartsInTheControlColumn() throws {
        let view = SettingsView(defaults: nil, domain: nil, app: app())
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.contentView?.layoutSubtreeIfNeeded()
        let content = try #require(window.contentView)
        func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
        func all(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(all) }
        let views = all(content)
        let popUp = try #require(views.first { $0 is NSPopUpButton }, "the Language pop-up")
        let stepper = try #require(views.first { $0 is NSStepper }, "the stepper")
        // The row is the views at the height of the stepper: the label, the value, and the stepper.
        let row = content.subviews.filter { abs(frame($0).midY - frame(stepper).midY) < 8 }
            .sorted { frame($0).minX < frame($1).minX }
        #expect(row.count == 3, "the label, the value, and the stepper: \(row.map(frame))")
        let value = try #require(row.dropFirst().first)
        let column = popUp.convert(popUp.alignmentRect(forFrame: popUp.bounds), to: nil).minX
        let start = frame(value).minX
        #expect(abs(start - column) < 4, "the value starts at \(start), the column at \(column)")
    }

    @Test func theLengthTextUsesTheNumberFormatOfTheLocale() {
        #expect(preRollLengthText(seconds: 10, locale: Locale(identifier: "en")) == "10 s")
    }
}
