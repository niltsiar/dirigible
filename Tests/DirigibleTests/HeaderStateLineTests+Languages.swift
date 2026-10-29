import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The track header rows draw each text from the table of a language (decision 0010, **Views**),
/// so a long text in any language shows here. The suite is slow-gated: see `HeaderStateLineTests`.
extension HeaderStateLineTests {
    enum Group: String { case states, other }

    /// The header widths of the gates of `TrackHeaders`, one point under each gate, and the
    /// standard widths.
    static var widths: [Double] {
        let gates = [
            TrackHeaders.muteSoloWidth, TrackHeaders.muteSoloTwoLineWidth, TrackHeaders.monitorWidth,
            TrackHeaders.monitorTwoLineWidth, TrackHeaders.layoutWidth, TrackHeaders.compactLoudnessWidth,
            TrackHeaders.faderTwoLineWidth,
        ]
        return Set([180, 340, 480] + gates + gates.map { $0 - 1 }).sorted()
    }

    /// Four tracks with the row texts of the header:
    /// - `states`: device lost, write failed, and retry stopped (armed), then a stereo track with no state.
    /// - `other`: dropped frames with a short-term value, an app track in no sound, an app track
    ///   that waits for its app, and a track whose name draft is empty (the placeholder).
    func headerModel(_ group: Group) async throws -> (SessionWindow, Studio) {
        let url = folder.url.appending(path: "\(group.rawValue).dirigible")
        try await Task.detached {
            var session = Session(sampleRate: 48_000)
            for (n, layout) in [ChannelLayout.mono, .mono, .mono, group == .states ? .stereo : .mono].enumerated() {
                try session.addTrack(TrackID("t\(n + 1)"), name: "T\(n + 1)", layout: layout)
            }
            for id in ["t1", "t2", "t3"] where group == .states || id == "t1" {
                try session.setRoute(.device(uid: "mic", channels: .mono(1)), track: TrackID(id))
            }
            try session.write(to: url)
        }.value
        let model = await app.open(url)
        let studio = try #require(await model.opened() ? model.studio : nil)
        switch group {
        case .states:
            for (id, state) in [("t1", LiveTrack.State.deviceLost), ("t2", .writeFailed), ("t3", .retryStopped)] {
                studio.liveTracks[TrackID(id)] = LiveTrack(state: state, droppedFrames: 0, peak: 0)
            }
            model.armed = ["t1", "t2", "t3"]
        case .other:
            model.appNames = ["com.microsoft.teams2": "Microsoft Teams", "us.zoom.xos": "zoom.us"]
            model.setAppRoute("com.microsoft.teams2", track: "t2")
            model.setAppRoute("us.zoom.xos", track: "t3")
            studio.liveTracks["t1"] = LiveTrack(
                state: .recording, droppedFrames: 3, peak: 0.1, shortTerm: LUFS(value: -17.4))
            studio.liveTracks["t2"] = LiveTrack(state: .noSound, droppedFrames: 0, peak: 0)
            studio.liveTracks["t3"] = LiveTrack(state: .waitingForApp, droppedFrames: 0, peak: 0)
            model.armed = ["t1"]
            model.drafts["t4"] = ""
        }
        return (model, studio)
    }

    /// The lines of the red text on line 2 of row 3 (retry stopped) in lanes of `lane` pt, and how
    /// far above the bottom of that lane the text ends (nil with no red). The scan runs from the
    /// top of the route menu of the row to the bottom of the window, so a text that leaves its lane
    /// shows. Needs `model` to be the `states` group.
    func retryStoppedText(
        _ model: SessionWindow, _ studio: Studio, lane: Double, width: Double
    ) async throws -> (lines: Int, above: Double?) {
        let header = try HeaderRowTests()
        let (window, host) = header.rows(model, studio, laneHeight: lane, width: width)
        defer { window.close() }
        window.orderFront(nil)
        drawNow(window)
        try await Task.sleep(for: .milliseconds(200))
        let menus = header.controls(host, in: host).filter { $0.kind == "route" }.map(\.frame)
        let menu = try #require(menus.first { $0.midY > 2 * lane && $0.midY < 3 * lane })
        let capture = try await TimelineColorTests.capture(window)
        let red = try stride(from: menu.minY, to: 4 * lane, by: 0.5).map { y in
            let rect = host.convert(NSRect(x: menu.maxX + 1, y: y, width: width - menu.maxX - 1, height: 0.5), to: nil)
            return try TimelineRulerTests.pixels(of: rect, capture, window).contains(where: HeaderRowTests.isRed)
        }
        let low = red.lastIndex(of: true).map { menu.minY + Double($0 + 1) / 2 }
        return (Self.bands(red), low.map { 3 * lane - $0 })
    }

    /// Row texts in each language of the app: no view of a row goes past the right padding,
    /// at each gate width, in 50 pt and 100 pt lanes. The retry-stopped text has no line limit: in
    /// the 100 pt lanes, at a width where the English text is whole and ends 2 pt or more above the
    /// lane bottom, the text of each language is whole and ends there too. A width where the
    /// lane cuts the English text has no such assert. The line counts are in the output.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func everyRowViewStaysInsideInEachLanguage() async throws {
        let header = try HeaderRowTests()
        let languages = ["en"] + AppLanguage.allCases.map(\.rawValue).filter { $0 != "en" }
        var englishRoom: [Double: Bool] = [:]
        for group in [Group.states, .other] {
            let (model, studio) = try await headerModel(group)
            for language in languages {
                let table = try stringsTable(language)
                try await withStrings(language) {
                    for lane in [50.0, 100] {
                        for width in Self.widths {
                            let label = "\(group) \(language), \(lane) pt lanes at \(width) pt"
                            let (window, host) = header.rows(model, studio, laneHeight: lane, width: width)
                            let out = header.outside(host, width: width)
                            #expect(out.isEmpty, "inside the row: \(label): \(out)")
                            if group == .other {
                                if lane == 100 {
                                    // SwiftUI draws the title: its width is the check. The key is far wider.
                                    let text = table[L10n.trackNoSoundPrivacy.rawValue] ?? ""
                                    let drawn = NSString(string: text).size(withAttributes: [
                                        .font: NSFont.systemFont(ofSize: 13)
                                    ])
                                    let labels = Self.buttons(host).flatMap(\.subviews).filter {
                                        String(describing: type(of: $0)) == "ContentViewHost"
                                    }
                                    let widths = labels.map(\.frame.width)
                                    #expect(
                                        widths.contains { $0 <= drawn.width && $0 >= 0.8 * drawn.width },
                                        "the Privacy title is the table text: \(label): \(widths) for \(drawn.width)")
                                }
                                let placeholders = Self.textFields(host).map { $0.placeholderString }
                                #expect(
                                    placeholders.contains { $0 == table[L10n.trackName.rawValue] },
                                    "the name placeholder is the table text: \(label)")
                            }
                            if group == .states, lane == 100 {
                                let (lines, above) = try await retryStoppedText(
                                    model, studio, lane: lane, width: width)
                                // A taller lane shows whether the lane cuts the text: SwiftUI ends it with an ellipsis.
                                let (uncut, _) = try await retryStoppedText(model, studio, lane: 300, width: width)
                                let fits = lines == uncut && (above ?? 0) >= 2
                                print(
                                    "LANE \(language) \(width) pt: \(lines) lines, \(uncut) lines in a 300 pt lane, ends \(above.map { "\($0)" } ?? "none") pt above the lane bottom"
                                )
                                if language == "en" {
                                    englishRoom[width] = fits
                                } else if englishRoom[width] == true {
                                    #expect(fits, "the retry-stopped text stays in its lane: \(label)")
                                }
                            }
                            window.close()
                        }
                    }
                }
            }
            await model.close()
        }
        print("LANE english room: \(englishRoom.sorted { $0.key < $1.key })")
    }

    static func buttons(_ view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
    }

    static func textFields(_ view: NSView) -> [NSTextField] {
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(textFields)
    }
}
