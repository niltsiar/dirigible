import AppKit
import DirigibleCore
import Foundation
import ObjectiveC
import SwiftUI
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Run 2026-10-11-ui-polish-header C3: in a row of 80 pt or more, the no-sound state takes one
/// line, in English and in Spanish. The test runner has no string table, so the test puts the
/// en or es table into `Bundle.localizedString(forKey:value:table:)` and restores it after. That
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
    /// A verbatim text of `L10n` (the state) takes the table. A SwiftUI `LocalizedStringKey` (the
    /// "Privacy…" title) does not, in any of these variants: it shows its key, which is wider than
    /// the English and the Spanish title, so the button test is a worst case.
    func withStrings(_ language: String, _ body: () async throws -> Void) async throws {
        let table = try stringsTable(language)
        let three: @convention(block) (Bundle, String, String?, String?) -> String = { _, key, value, _ in
            table[key] ?? value ?? key
        }
        let four: @convention(block) (Bundle, String, String?, String?, AnyObject?) -> String = { _, key, value, _, _ in
            table[key] ?? value ?? key
        }
        let lookups: [(String, Any)] = [
            ("localizedStringForKey:value:table:", three),
            ("localizedStringForKey:value:table:localization:", four),
            ("localizedStringForKey:value:table:localizations:", four),
            ("_localizedStringForKey:value:table:localizations:", four),
        ]
        var olds: [(Method, IMP)] = []
        defer { for (method, old) in olds { method_setImplementation(method, old) } }
        for (name, block) in lookups {
            let method = try #require(class_getInstanceMethod(Bundle.self, NSSelectorFromString(name)), "\(name)")
            olds.append((method, method_setImplementation(method, imp_implementationWithBlock(block))))
        }
        try await body()
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theStateTakesOneLine() async throws {
        let (model, studio) = try await timelineModel(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 1), app: app)
        model.appNames["com.microsoft.teams2"] = "Microsoft Teams"
        model.setAppRoute("com.microsoft.teams2", track: "t2")
        #expect(studio.session.track("t2")?.route == .app(bundleID: "com.microsoft.teams2"))
        studio.liveTracks["t1"] = LiveTrack(state: .recording, droppedFrames: 0, peak: 0.2)
        studio.liveTracks["t2"] = LiveTrack(state: .noSound, droppedFrames: 0, peak: 0)
        let header = try HeaderRowTests()
        for language in ["en", "es"] {
            try await withStrings(language) {
                #expect(L10n.trackStateNoSound.format("A").count > 60, "the \(language) table is in use")
                for lane in [80.0, 100, 200] {
                    for width in [180.0, 340] {
                        let label = "\(language), \(lane) pt lanes at \(width) pt"
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
        await model.close()
    }
}
