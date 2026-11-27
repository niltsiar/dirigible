import AppKit
import DirigibleCore
import Foundation
import ObjectiveC
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 2026-10-11-ui-polish-header C3: in a row of 80 pt or more, the no-sound state takes one
/// line, in each language. The test runner has no string table, so the test puts the
/// table of the language into `Bundle.localizedString(forKey:value:table:)` and restores it after. That
/// change is for the whole process, so the test is slow-gated: `make test-slow` runs it alone
/// (`--no-parallel`), and no suite that reads a key as its text runs at the same time.
@Suite(.serialized) @MainActor struct HeaderStateLineTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)

    init() throws {
        NSWindow.allowsAutomaticWindowTabbing = false
        folder = try TemporaryFolder()
    }

    /// Runs `body` with the strings of `language`, and restores the lookups of the test runner.
    /// A verbatim text of `L10n` takes the table. A SwiftUI `LocalizedStringKey` does not, in any
    /// of these variants: it shows its key. The header rows draw each text verbatim (decision 0010,
    /// **Views**), so the tests draw them with the table. Only `Bundle.main`, which `L10n` reads,
    /// takes the table: each other bundle keeps its own lookup.
    func withStrings(_ language: String, _ body: () async throws -> Void) async throws {
        let table = try stringsTable(language)
        let lookups = [
            "localizedStringForKey:value:table:", "localizedStringForKey:value:table:localization:",
            "localizedStringForKey:value:table:localizations:", "_localizedStringForKey:value:table:localizations:",
        ]
        var olds: [(Method, IMP)] = []
        defer { for (method, old) in olds { method_setImplementation(method, old) } }
        for name in lookups {
            let selector = NSSelectorFromString(name)
            let method = try #require(class_getInstanceMethod(Bundle.self, selector), "\(name)")
            let block = Self.mainBundleLookup(selector, old: method_getImplementation(method), table: table)
            olds.append((method, method_setImplementation(method, imp_implementationWithBlock(block))))
        }
        try await body()
    }

    /// The block of the lookup `selector`: the value of `table` for `Bundle.main`, and the `old`
    /// lookup for each other bundle. It is nonisolated, because each thread can look up a string.
    nonisolated static func mainBundleLookup(_ selector: Selector, old imp: IMP, table: [String: String]) -> Any {
        func text(_ key: NSString, _ value: NSString?) -> NSString {
            table[key as String].map { $0 as NSString } ?? value ?? key
        }
        typealias OldThree = @convention(c) (Bundle, Selector, NSString, NSString?, NSString?) -> NSString?
        typealias Three = @convention(block) (Bundle, NSString, NSString?, NSString?) -> NSString?
        typealias OldFour = @convention(c) (Bundle, Selector, NSString, NSString?, NSString?, AnyObject?) -> NSString?
        typealias Four = @convention(block) (Bundle, NSString, NSString?, NSString?, AnyObject?) -> NSString?
        if NSStringFromSelector(selector).hasSuffix("table:") {
            let oldThree = unsafeBitCast(imp, to: OldThree.self)
            let three: Three = { bundle, key, value, file in
                bundle === Bundle.main ? text(key, value) : oldThree(bundle, selector, key, value, file)
            }
            return three
        }
        let oldFour = unsafeBitCast(imp, to: OldFour.self)
        let four: Four = { bundle, key, value, file, languages in
            bundle === Bundle.main ? text(key, value) : oldFour(bundle, selector, key, value, file, languages)
        }
        return four
    }

    /// The rows of 0.5 pt of row 1 (the no-sound track) that have orange pixels, from 8 pt to
    /// `width - 8`. The app route arms the track, and the edge of the red arm box has orange
    /// pixels, so the rows of `arm` start right of it.
    func orangeRows(_ host: NSView, _ window: NSWindow, lane: Double, arm: NSRect, width: Double) async throws
        -> [Bool]
    {
        let capture = try await TimelineColorTests.capture(window)
        return try stride(from: 0.0, to: lane, by: 0.5).map { y in
            let left = (arm.minY - 1...arm.maxY + 1).contains(lane + y) ? arm.maxX + 1 : 8
            let rect = host.convert(NSRect(x: left, y: lane + y, width: width - 8 - left, height: 0.5), to: nil)
            return try TimelineRulerTests.pixels(of: rect, capture, window).contains(where: HeaderRowTests.isOrange)
        }
    }

    /// The alignment rect of the lowest button in row 1, in the coordinates of `host`.
    static func lowestButton(_ host: NSView, lane: Double) -> NSRect? {
        func buttons(_ view: NSView) -> [NSButton] {
            ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
        }
        return buttons(host).compactMap { button -> NSRect? in
            guard let superview = button.superview else { return nil }
            let frame = superview.convert(button.alignmentRect(forFrame: button.frame), to: host)
            return frame.midY > lane && frame.midY < 2 * lane ? frame : nil
        }.max { $0.midY < $1.midY }
    }

    /// The bands of orange rows: a gap of 2 pt or more starts a new band. A wrapped text gives one
    /// band per line.
    static func bands(_ rows: [Bool]) -> Int {
        var (bands, gap) = (0, 4)
        for orange in rows {
            if orange, gap >= 4 { bands += 1 }
            gap = orange ? 0 : gap + 1
        }
        return bands
    }

    /// The swap gives the table to `Bundle.main` only. `+[NSRulerView initialize]` reads its unit
    /// names from the AppKit bundle, and a swapped unit name stopped the test process.
    @Test func aStringSwapLeavesOtherBundlesAlone() async throws {
        let appKit = Bundle(for: NSView.self)
        let unit = appKit.localizedString(forKey: "in", value: "", table: "Ruler")
        try #require(!unit.isEmpty, "AppKit has the ruler unit in")
        try await withStrings("de") {
            #expect(appKit.localizedString(forKey: "in", value: "", table: "Ruler") == unit)
            #expect(L10n.alertCancel.text == "Abbrechen")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theStateTakesOneLine() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 1), app: app)
        model.appNames["com.microsoft.teams2"] = "Microsoft Teams"
        model.setAppRoute("com.microsoft.teams2", track: "t2")
        #expect(studio.session.track("t2")?.route == .app(bundleID: "com.microsoft.teams2"))
        studio.liveTracks["t1"] = LiveTrack(state: .recording, droppedFrames: 0, peak: 0.2)
        let header = try HeaderRowTests()
        for (state, text) in [(LiveTrack.State.noSound, L10n.trackStateNoSound), (.noAccess, .trackStateNoAccess)] {
            studio.liveTracks["t2"] = LiveTrack(state: state, droppedFrames: 0, peak: 0)
            for language in AppLanguage.allCases.map(\.rawValue) {
                try await withStrings(language) {
                    #expect(text.format("A").count > 60, "the \(language) table is in use")
                    try await checkLines(model, studio, header, "\(state), \(language)")
                }
            }
        }
        await model.close()
    }

    /// One line of state text and the Privacy button on line 3 of row 1, at each lane and width.
    func checkLines(_ model: SessionWindow, _ studio: Studio, _ header: HeaderRowTests, _ name: String) async throws {
        for lane in [80.0, 100, 200] {
            for width in [180.0, 340] {
                let label = "\(name), \(lane) pt lanes at \(width) pt"
                let (window, host) = header.rows(model, studio, laneHeight: lane, width: width)
                window.orderFront(nil)
                drawNow(window)
                try await Task.sleep(for: .milliseconds(200))
                let arm = try #require(header.flagBoxes(host, in: host).first { $0.midY > lane })
                let orange = try await orangeRows(host, window, lane: lane, arm: arm, width: width)
                #expect(Self.bands(orange) == 1, "one line of state text: \(label)")
                #expect(!orange.suffix(4).contains(true), "no orange in the last 2 pt of the row: \(label)")
                let privacy = try #require(Self.lowestButton(host, lane: lane), "a button on line 3: \(label)")
                // The route menu is the highest route-kind host of row 1; the button is under it.
                let menus = header.controls(host, in: host).filter { $0.kind == "route" }.map(\.frame)
                let row = menus.filter { $0.midY > lane && $0.midY < 2 * lane }
                let route = try #require(row.min { $0.minY < $1.minY }).maxY
                #expect(
                    privacy.minY >= route && privacy.minX >= 8 && privacy.maxX <= width - 8,
                    "the Privacy button is on line 3, inside the row: \(label): \(privacy)")
                window.close()
            }
        }
    }
}
