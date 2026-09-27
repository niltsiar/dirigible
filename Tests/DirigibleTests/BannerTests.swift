import AppKit
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// The pure values of the subtitle and the banners (ui-shell criteria A12, A15).
struct BannerValueTests {
    /// A12: the rate in kHz, "Tracks: N" with no plural form, and the time left in units that
    /// Foundation gives. The test process has no app tables, so the labels come from each table.
    @Test func theSubtitleShowsRateTracksAndTimeLeft() throws {
        for (language, identifier) in [("en", "en_US"), ("es", "es_ES")] {
            let table = try stringsTable(language)
            let locale = Locale(identifier: identifier)
            let text = { (key: L10n) in table[key.rawValue] ?? "" }
            let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes], width: .abbreviated).locale(locale)
            let left = Duration.seconds(7_800).formatted(style)
            #expect(
                subtitleText(rate: 48_000, tracks: 3, recordTimeLeft: .seconds(7_800), locale: locale, text: text)
                    == "48 kHz · \(text(.subtitleTracks)) 3 · \(text(.subtitleRecordTime)) \(left)")
            #expect(
                subtitleText(rate: 48_000, tracks: 0, recordTimeLeft: nil, locale: locale, text: text)
                    == "48 kHz · \(text(.subtitleTracks)) 0")
        }
        #expect(
            subtitleText(rate: 44_100, tracks: 1, recordTimeLeft: nil, locale: Locale(identifier: "es_ES")).hasPrefix(
                "44,1 kHz"))
        #expect(try stringsTable("en")[L10n.subtitleTracks.rawValue] == "Tracks:")
    }

    /// A13: before a take under 60 min, during a take under 10 min, and 60 s of hysteresis.
    @Test func theLowRecordTimeRuleHasHysteresis() {
        #expect(!showsLowRecordTime(left: .seconds(3_600), recording: false, shownBefore: false))
        #expect(showsLowRecordTime(left: .seconds(3_599), recording: false, shownBefore: false))
        #expect(showsLowRecordTime(left: .seconds(3_659), recording: false, shownBefore: true))
        #expect(!showsLowRecordTime(left: .seconds(3_660), recording: false, shownBefore: true))
        #expect(!showsLowRecordTime(left: .seconds(600), recording: true, shownBefore: false))
        #expect(showsLowRecordTime(left: .seconds(599), recording: true, shownBefore: false))
        #expect(showsLowRecordTime(left: .seconds(659), recording: true, shownBefore: true))
        #expect(!showsLowRecordTime(left: .seconds(660), recording: true, shownBefore: true))
    }

    /// Code gate 1 item 3: the banner rounds the time left up, so the last minute says 1 min.
    @Test func theLowRecordTimeBannerRoundsUp() {
        #expect(lowRecordTimeMinutes(.seconds(30)) == 1)
        #expect(lowRecordTimeMinutes(.seconds(0)) == 1)
        #expect(lowRecordTimeMinutes(.seconds(300)) == 5)
        #expect(lowRecordTimeMinutes(.milliseconds(3_594_000)) == 60)
    }

    /// A15, A16: the symbol of each kind, the kind of each banner, its text key, and its
    /// announcement.
    @Test func eachBannerKindHasItsSymbolAndAction() {
        #expect(
            WindowBanner.Kind.allCases.map(\.symbol) == [
                "exclamationmark.triangle.fill", "xmark.octagon.fill", "info.circle", "record.circle",
            ])
        let banners: [(WindowBanner, WindowBanner.Kind, String, NSAccessibilityPriorityLevel?)] = [
            (.playbackStopped(.outputChanged), .warning, L10n.transportStopOutputChanged.text, .high),
            (.missingMedia(["a.wav"]), .error, L10n.mediaMissing.text, .medium),
            (.lowRecordTime(minutes: 5), .warning, L10n.bannerLowRecordTime.text, .high),
        ]
        for (banner, kind, text, announcement) in banners {
            #expect(banner.kind == kind, "\(banner)")
            #expect(banner.text == text, "\(banner)")
            #expect(banner.announcement == announcement, "\(banner)")
        }
        for language in ["en", "es"] {
            let table = (try? stringsTable(language)) ?? [:]
            for key in [L10n.bannerLowRecordTime, .mediaMissing, .transportStopOutputChanged, .transportRecordOver] {
                #expect(table[key.rawValue]?.hasSuffix(".") == true, "\(language) \(key): a fact, then an action")
                #expect((table[key.rawValue]?.split(separator: ".").count ?? 0) >= 2, "\(language) \(key)")
            }
        }
    }
}

/// The banners and the record time on a real session window (ui-shell criteria A12 to A18).
@Suite(.serialized) @MainActor struct BannerTests {
    let folder: TemporaryFolder
    let app = AppDelegate(recordings: nil)
    let hal = CountingHAL()
    /// The free bytes that the tests give the disk checks.
    let free = OSAllocatedUnfairLock(initialState: Int64.max)

    init() throws {
        folder = try TemporaryFolder()
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// A window of `tracks` tracks on channel 1 of `duo` with 10 s clips, the counting HAL, and
    /// free bytes from `free`.
    func open(tracks: Int = 1, seconds: Int = 10, name: String? = nil) async throws
        -> (SessionWindow, Studio, NSWindow, SessionChrome)
    {
        var url = try await timelinePackage(
            in: folder.url, tracks: tracks, seconds: seconds, audio: true, device: "duo")
        if let name {
            let renamed = folder.url.appending(path: "\(name).dirigible")
            try FileManager.default.moveItem(at: url, to: renamed)
            url = renamed
        }
        let model = await app.open(url)
        let studio = try #require(await model.opened() ? model.studio : nil)
        studio.environment = hal.environment
        studio.environment.playerOutput = .offline
        studio.environment.diskCheckInterval = .milliseconds(50)
        let free = free
        studio.environment.freeBytes = { _ in free.withLock { $0 } }
        let chrome = try #require(model.chrome)
        await until("the toolbar has its items") { chrome.time != nil }
        return (model, studio, try #require(model.window), chrome)
    }

    /// The free bytes that give `seconds` of record time to one mono track at 48 kHz.
    func setFree(seconds: Int) { free.withLock { $0 = diskMargin + Int64(seconds) * 7 * 48_000 } }

    func lowTime(_ model: SessionWindow) -> Bool { model.shown.banners.contains { $0.key == "lowRecordTime" } }

    /// Sets the free space, reads it again, and waits until the window has the new time.
    func read(seconds: Int, _ model: SessionWindow, _ chrome: SessionChrome) async {
        setFree(seconds: seconds)
        chrome.refreshRecordTime()
        await until(limit: .seconds(10), "the read gives \(seconds) s") {
            model.idleRecordTimeLeft == .seconds(seconds)
        }
    }

    // MARK: A12

    @Test func theWindowSubtitleFollowsTheTracks() async throws {
        let (model, studio, window, _) = try await open()
        await until(limit: .seconds(5), "the subtitle has the track count") {
            window.subtitle.contains("\(L10n.subtitleTracks.text) 1")
        }
        #expect(window.subtitle.hasPrefix("48 kHz · \(L10n.subtitleTracks.text) 1"), "\(window.subtitle)")

        model.addTrack()

        #expect(studio.session.tracks.count == 2)
        await until(limit: .seconds(5), "Add Track changes the count") {
            window.subtitle.contains("\(L10n.subtitleTracks.text) 2")
        }
        #expect(window.subtitle.contains("\(L10n.subtitleTracks.text) 2"), "\(window.subtitle)")
        await model.close()
    }

    // MARK: A13

    /// Plan gate 2 items 4 and 5: the first read waits at an async gate; a second read gives
    /// 5 min; then the first read returns 90 min. The stored value stays 5 min.
    @Test func anOldRecordTimeReadNeverWinsOverANewOne() async throws {
        let (model, _, _, chrome) = try await open()
        await until("the read at open ends") { model.idleRecordTimeLeft != nil }
        let gate = AsyncGate()
        var calls = 0
        chrome.readRecordTime = { _ in
            calls += 1
            if calls == 1 {
                await gate.wait()
                return .seconds(5_400)
            }
            return .seconds(300)
        }
        let reads = chrome.recordTimeReads

        chrome.refreshRecordTime()
        await gate.entered()
        chrome.refreshRecordTime()
        await until(limit: .seconds(10), "the new read writes 5 min") { model.idleRecordTimeLeft == .seconds(300) }
        gate.open()
        await until(limit: .seconds(10), "the old read ends") { chrome.recordTimeReads == reads + 2 }

        #expect(model.idleRecordTimeLeft == .seconds(300), "the old read wrote over the new one")
        await until(limit: .seconds(5), "the banner follows the new read") { lowTime(model) }
        #expect(model.shown.banners == [.lowRecordTime(minutes: 5)])
        await model.close()
    }

    @Test func theIdleRecordTimeBannerHasHysteresis() async throws {
        let (model, _, _, chrome) = try await open()
        for (seconds, shows) in [(3_700, false), (3_599, true), (3_630, true), (3_660, false)] {
            await read(seconds: seconds, model, chrome)
            await until(limit: .seconds(5), "\(seconds) s: the banner follows") { lowTime(model) == shows }
            #expect(lowTime(model) == shows, "\(seconds) s")
        }
        setFree(seconds: 3_000)
        model.armed = []
        await until(limit: .seconds(5), "no armed track: no read") { model.idleRecordTimeLeft == nil }
        #expect(!lowTime(model), "a banner with no armed track")

        model.armed = ["t1"]

        await until(limit: .seconds(10), "an arm change reads again") { model.idleRecordTimeLeft == .seconds(3_000) }
        await until(limit: .seconds(5), "the banner shows after the arm") { lowTime(model) }
        #expect(lowTime(model))
        await model.close()
    }

    @Test func theTakeRecordTimeBannerHasHysteresis() async throws {
        let (model, studio, _, _) = try await open()
        setFree(seconds: 700)
        await model.record()
        try #require(model.canStop)
        for (seconds, shows) in [(700, false), (599, true), (659, true), (660, false)] {
            setFree(seconds: seconds)
            await until(limit: .seconds(10), "the disk watch gives \(seconds) s") {
                studio.recordTimeLeft == .seconds(seconds)
            }
            await until(limit: .seconds(5), "\(seconds) s in a take: the banner follows") { lowTime(model) == shows }
            #expect(lowTime(model) == shows, "\(seconds) s in a take")
        }
        await hal.feed(seconds: 0.2)
        await model.stop()
        await until("the finalize ends") { studio.transport == .idle }
        await model.close()
    }

    // MARK: A14

    @Test func theRecordTimeBannerShowsAtTheMinimumWidthWithALongName() async throws {
        let (model, _, window, chrome) = try await open(name: String(repeating: "Interview ", count: 12))
        try #require(window.title.count == 120)
        window.setContentSize(NSSize(width: 500, height: 600))
        await until(limit: .seconds(10), "the window takes its minimum width") {
            window.layoutIfNeeded()
            return window.contentLayoutRect.width == 720
        }
        await read(seconds: 300, model, chrome)
        await until(limit: .seconds(5), "the banner shows") { lowTime(model) }
        #expect(lowTime(model))
        guard !screenIsLocked() else {
            print("BannerTests: the screen is locked; the banner frame at 720 pt is a manual check")
            await model.close()
            return
        }

        var banner: (label: String, role: String, frame: NSRect)?
        await until(limit: .seconds(10), "the accessibility tree has the banner") {
            window.contentView?.layoutSubtreeIfNeeded()
            banner = accessibilityElements(under: window.contentView as Any).first {
                $0.label.contains(L10n.bannerLowRecordTime.text)
            }
            return banner != nil
        }
        let frame = try #require(banner?.frame)
        #expect(window.frame.contains(frame), "\(frame) is not inside \(window.frame)")
        #expect(banner?.label.hasPrefix(L10n.bannerKindWarning.text) == true, "\(banner?.label ?? "")")
        await model.close()
    }

    // MARK: A16

    /// A new banner is announced once, at its priority; record-over and the time display are not.
    @Test func newBannersAreAnnounced() async throws {
        let (model, studio, _, chrome) = try await open(tracks: TimelineViewTests.tracksThatDoNotFit, seconds: 20)
        var heard: [String] = []
        chrome.announce = { text, priority in heard.append("\(priority.rawValue) \(text)") }
        let high = NSAccessibilityPriorityLevel.high.rawValue
        chrome.readRecordTime = { _ in .seconds(300) }

        chrome.refreshRecordTime()
        await until(limit: .seconds(5), "the low time is announced") { heard.count == 1 }
        chrome.readRecordTime = { _ in .seconds(240) }
        chrome.refreshRecordTime()
        await until(limit: .seconds(5), "the banner has 4 min") {
            model.shown.banners.contains(.lowRecordTime(minutes: 4))
        }
        studio.play.playbackStop = .outputChanged
        await until(limit: .seconds(5), "the playback stop is announced") { heard.count == 2 }
        studio.missingMedia = ["f1": .missing]
        await until(limit: .seconds(5), "the missing media is announced") { heard.count == 3 }
        await until("the window shows the lanes") { model.timelineView?.window != nil }
        model.timelineView?.viewWillMove(toWindow: nil)
        model.armed = [TrackID("t\(TimelineViewTests.tracksThatDoNotFit)")]
        await studio.perform(.seek(.frame(100_000)))
        await until(limit: .seconds(5), "the record-over warning shows") { model.shown.recordOver }

        #expect(
            heard == [
                "\(high) \(L10n.bannerLowRecordTime.text)", "\(high) \(L10n.transportStopOutputChanged.text)",
                "\(NSAccessibilityPriorityLevel.medium.rawValue) \(L10n.mediaMissing.text)",
            ])
        await model.close()
    }

    // MARK: A17, A18

    /// The frame check comes after a body run of the overlay that shows the warning, so it sees
    /// the lanes with the overlay. The count is read before the arm, so no run is missed.
    @Test func theRecordOverBannerDoesNotMoveTheLanes() async throws {
        let (model, studio, window, _) = try await open(tracks: TimelineViewTests.tracksThatDoNotFit, seconds: 20)
        await until("the window shows the lanes") { model.timelineView?.window != nil }
        let view = try #require(model.timelineView)
        view.viewWillMove(toWindow: nil)
        model.armed = []
        await studio.perform(.seek(.frame(100_000)))
        // No row above the lanes: the lanes take the whole content height. The read at open can
        // show a low-time row that SwiftUI removes later.
        await until(limit: .seconds(10), "the lanes fill the content") {
            window.contentView?.layoutSubtreeIfNeeded()
            return model.shown.banners.isEmpty && view.frame.height == window.contentLayoutRect.height
        }
        let before = view.convert(view.bounds, to: nil)
        let shows = model.overlayShows

        model.armed = [TrackID("t\(TimelineViewTests.tracksThatDoNotFit)")]
        await until(limit: .seconds(10), "the overlay body shows the warning") {
            window.contentView?.layoutSubtreeIfNeeded()
            return model.overlayShows > shows
        }

        #expect(model.shown.recordOver)
        #expect(view.convert(view.bounds, to: nil) == before, "the overlay moved the lanes")
        if !screenIsLocked() {
            #expect(
                accessibilityElements(under: window.contentView as Any).contains {
                    $0.label.contains(L10n.transportRecordOver.text)
                }, "the overlay is not in the accessibility tree")
        }
        await model.close()
    }

    @Test func theTransportWarningsAreBanners() async throws {
        let (model, studio, window, _) = try await open()
        studio.play.playbackStop = .outputChanged
        studio.missingMedia = ["f1": .missing]
        await until(limit: .seconds(5), "the banner list has both") { model.shown.banners.count == 2 }
        #expect(model.shown.banners.map(\.kind) == [.warning, .error])
        guard !screenIsLocked() else {
            print("BannerTests: the screen is locked; the banner accessibility tree is a manual check")
            await model.close()
            return
        }
        var elements: [(label: String, role: String, frame: NSRect)] = []
        await until(limit: .seconds(10), "the banners show") {
            window.contentView?.layoutSubtreeIfNeeded()
            elements = accessibilityElements(under: window.contentView as Any)
            return elements.contains { $0.label.contains(L10n.mediaMissing.text) }
                && elements.contains { $0.label.contains(L10n.transportStopOutputChanged.text) }
        }
        let stop = elements.first { $0.label.contains(L10n.transportStopOutputChanged.text) }
        let media = elements.first { $0.label.contains(L10n.mediaMissing.text) }
        #expect(stop?.label.hasPrefix(L10n.bannerKindWarning.text) == true, "\(stop?.label ?? "none")")
        #expect(media?.label.hasPrefix(L10n.bannerKindError.text) == true, "\(media?.label ?? "none")")
        #expect(!elements.contains { $0.label.contains(L10n.menuRecordMonitor.text) }, "a Monitor Inputs check box")
        await model.close()
    }
}
